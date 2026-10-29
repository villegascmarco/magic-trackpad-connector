import AppKit
import Network

/// Owns the transfer flows and the automatic policy.
///
/// Policy (same code on both Macs; `role` only breaks ties):
/// - Lock: if this Mac holds the devices and the peer is awake *and unlocked*,
///   push them over.
/// - Sleep / lid close / shutdown: push if the peer is reachable at all (a
///   locked peer still beats a sleeping one). Sleep is held until done.
/// - Launch / wake / unlock ("arriving"): if nobody holds the devices, take
///   them. If the peer holds them, take them only when the peer is locked or
///   asleep — or, on wake/unlock (never launch), idle for `idleStealSeconds`.
/// - Every `reconcileInterval`: if the peer holds the devices but is locked or
///   asleep, take them; if nobody holds them, the primary (orchestrator) takes
///   them, or the secondary when the primary is unavailable. This is also the
///   recovery path after any failed transfer.
///
/// Bluetooth facts the flows rely on (Magic devices keep ONE host link key):
/// a handoff is "unpair while the link is up" on the sender (macOS sends the
/// HID Virtual Cable Unplug; the device forgets its host and becomes pairable)
/// followed by a fresh host-initiated pair on the receiver.
@MainActor
final class HandoffCoordinator {
    private let settings: AppSettings
    private let bonjour: BonjourService
    private let events: SystemEvents
    private let bt = BluetoothManager.shared

    private let reconcileInterval: TimeInterval = 15
    private let idleStealSeconds: Double = 120

    var onChange: (() -> Void)?

    private(set) var holdsHere = false
    private(set) var lastPeer: PeerState?
    private(set) var lastResult: String = ""
    /// A transfer this Mac is running or taking part in.
    private(set) var busy = false
    private var receivingUntil = Date.distantPast
    private var receiveWatchdog: Task<Void, Never>?
    private var lastBackgroundClaim = Date.distantPast
    private var timer: Timer?
    private var shuttingDown = false

    var isBusy: Bool { busy || Date() < receivingUntil }
    var isAvailable: Bool { !events.isLocked && !events.isAsleep && !shuttingDown }

    init(settings: AppSettings, bonjour: BonjourService, events: SystemEvents) {
        self.settings = settings
        self.bonjour = bonjour
        self.events = events
    }

    // MARK: - Lifecycle

    func start() {
        events.onLock = { [weak self] in
            Log.write("Sys", "screen locked")
            Task { await self?.leaving(reason: "lock", requirePeerUnlocked: true) }
        }
        events.onUnlock = { [weak self] in
            Log.write("Sys", "screen unlocked")
            Task { await self?.arriving(reason: "unlock") }
        }
        events.onWillSleep = { [weak self] done in
            Log.write("Sys", "system will sleep")
            Task {
                // Locking usually fires together with sleep and may already be
                // handing off: hold sleep until that transfer finishes too.
                await self?.waitWhileBusy(seconds: 20)
                await self?.leaving(reason: "sleep", requirePeerUnlocked: false)
                done()
            }
        }
        events.onDidWake = { [weak self] in
            Log.write("Sys", "system woke")
            Task {
                try? await Task.sleep(for: .seconds(3)) // let Wi-Fi come back
                await self?.arriving(reason: "wake")
            }
        }
        events.onWillPowerOff = { [weak self] in
            Log.write("Sys", "power off / logout")
            self?.shuttingDown = true
        }
        timer = Timer.scheduledTimer(withTimeInterval: reconcileInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reconcile(reason: "periodic", arriving: false) }
        }
        Task {
            await refresh()
            // The primary goes first so it wins when both Macs boot together.
            try? await Task.sleep(for: .seconds(settings.role == .primary ? 3 : 8))
            await arriving(reason: "launch")
        }
    }

    /// Called from applicationShouldTerminate. Hands the devices over when the
    /// Mac is shutting down / logging out; a plain Quit leaves them alone.
    func prepareForTermination() async {
        guard shuttingDown else { return }
        await waitWhileBusy(seconds: 20)
        await leaving(reason: "shutdown", requirePeerUnlocked: false)
    }

    private func waitWhileBusy(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while busy, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - State

    struct PeerState {
        let name: String
        let holds: Bool
        let available: Bool
        let idle: Double
        let busy: Bool
        let role: String
    }

    func refresh() async {
        let macs = settings.deviceMACs
        let held = await bt.run { [bt] in
            var any = false
            for mac in macs where bt.isConnected(mac) {
                any = true
                _ = bt.isHIDReady(mac) // starts settle()'s readiness clock early
            }
            return any
        }
        if held != holdsHere { Log.write("State", held ? "devices are here" : "devices are not here") }
        holdsHere = held
        onChange?()
    }

    func peerState(timeout: TimeInterval = 4) async -> PeerState? {
        guard let endpoint = bonjour.peerEndpoint else { lastPeer = nil; return nil }
        do {
            let r = try await sendToPeer(["action": "status", "devices": settings.deviceMACs], endpoint: endpoint, timeout: timeout)
            let state = PeerState(name: r["name"] as? String ?? bonjour.peerName ?? "Other Mac",
                                  holds: r["holds"] as? Bool ?? false,
                                  available: r["available"] as? Bool ?? false,
                                  idle: r["idle"] as? Double ?? 0,
                                  busy: r["busy"] as? Bool ?? false,
                                  role: r["role"] as? String ?? "")
            lastPeer = state
            return state
        } catch {
            lastPeer = nil
            return nil
        }
    }

    // MARK: - Manual actions

    /// Menu / hotkey: send the devices away if they are here, else bring them here.
    func toggle() async {
        await refresh()
        if holdsHere {
            report(await push(reason: "manual"))
        } else {
            report(await pull(reason: "manual"))
        }
    }

    private func report(_ result: Result<String, TransferError>) {
        switch result {
        case .success(let message):
            lastResult = message
        case .failure(let error):
            lastResult = error.message
            let alert = NSAlert()
            alert.messageText = "Magic Trackpad Connector"
            alert.informativeText = error.message
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        onChange?()
    }

    // MARK: - Automatic policy

    private func leaving(reason: String, requirePeerUnlocked: Bool) async {
        guard settings.autoHandoff, settings.isConfigured, !busy else { return }
        await refresh()
        guard holdsHere else { return }
        guard let peer = await peerState() else {
            Log.write("Policy", "\(reason): peer unreachable — keeping devices")
            return
        }
        if peer.busy || (requirePeerUnlocked && !peer.available) {
            Log.write("Policy", "\(reason): peer \(peer.busy ? "busy" : "not available") — keeping devices")
            return
        }
        Log.write("Policy", "\(reason): handing devices to \(peer.name)")
        lastResult = describe(await push(reason: reason))
    }

    private func arriving(reason: String) async {
        await reconcile(reason: reason, arriving: true)
    }

    /// After `prepare`, the sender releases and then sends `receive`. If it
    /// dies in between (shutdown kills apps within seconds), the device is
    /// pairable and nobody would pick it up: pair as soon as the sender
    /// vanishes, or when `receive` never comes.
    private func watchForAbandonedHandoff() {
        receiveWatchdog?.cancel()
        receiveWatchdog = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if Date() >= self.receivingUntil || self.busy { return } // receive/cancel arrived
                if await self.peerState(timeout: 1.5) == nil { break }  // sender gone
            }
            guard let self, !Task.isCancelled, !self.busy, Date() < self.receivingUntil else { return }
            Log.write("Flow", "sender vanished mid-handoff — acquiring")
            self.busy = true
            let macs = self.settings.deviceMACs
            _ = await self.bt.run { [bt = self.bt] in macs.allSatisfy { Self.acquireAfterRelease(bt, $0) } }
            self.busy = false
            self.receivingUntil = .distantPast
            await self.refresh()
        }
    }

    func reconcile(reason: String, arriving: Bool) async {
        guard settings.autoHandoff, settings.isConfigured, !isBusy, isAvailable else { return }
        await refresh()
        guard !holdsHere else { return }

        guard let peer = await peerState() else {
            // Peer off, asleep, or not running the app: first Mac up takes them.
            await claimInBackground(reason: "\(reason): peer unreachable", arriving: arriving)
            return
        }
        if peer.busy { return }

        if peer.holds {
            // Launch never takes from an unlocked holder; unlock/wake also
            // take from one that has been idle for a while.
            let idleSteal = arriving && reason != "launch" && peer.idle >= idleStealSeconds
            let peerInUse = peer.available && !idleSteal
            if peerInUse { return }
            Log.write("Policy", "\(reason): \(peer.name) holds the devices but is "
                      + (peer.available ? "idle \(Int(peer.idle))s" : "locked/asleep") + " — taking them")
            lastResult = describe(await pull(reason: reason))
            return
        }

        // Nobody holds them: the orchestrator recovers them, or the secondary
        // if the orchestrator can't use them right now.
        if settings.role == .primary || !peer.available {
            await claimInBackground(reason: "\(reason): devices are nowhere", arriving: arriving)
        }
    }

    /// Take devices that nobody holds. Rate-limited when not arriving: a
    /// switched-off trackpad shouldn't be paged every 15 s forever.
    private func claimInBackground(reason: String, arriving: Bool) async {
        if !arriving, Date().timeIntervalSince(lastBackgroundClaim) < 60 { return }
        lastBackgroundClaim = Date()
        Log.write("Policy", "\(reason) — claiming")
        busy = true
        defer { busy = false }
        let macs = settings.deviceMACs
        _ = await bt.run { [bt] in macs.allSatisfy { Self.claim(bt, $0) } }
        await refresh()
    }

    // MARK: - Transfer flows

    struct TransferError: Error { let message: String }

    private func describe(_ result: Result<String, TransferError>) -> String {
        switch result {
        case .success(let m): return m
        case .failure(let e): return e.message
        }
    }

    func push(reason: String, abandon: Bool = false) async -> Result<String, TransferError> {
        guard !busy else { return .failure(.init(message: "A transfer is already in progress.")) }
        guard settings.isConfigured else { return .failure(.init(message: "No device configured. Open Settings.")) }
        guard let endpoint = bonjour.peerEndpoint else {
            return .failure(.init(message: "The other Mac is not reachable. Make sure the app is running there."))
        }
        busy = true
        defer { busy = false }

        do {
            // Pre-flight: nothing is touched unless the receiver can take them.
            _ = try await sendToPeer(["action": "prepare", "devices": settings.deviceMACs], endpoint: endpoint, timeout: 5)
        } catch {
            return .failure(.init(message: "The other Mac can't receive the devices: \(error.localizedDescription)\nNothing was changed."))
        }

        Log.write("Flow", "push(\(reason)): releasing")
        let macs = settings.deviceMACs
        let confirm = reason != "shutdown"
        let released = await bt.run { [bt] in macs.allSatisfy { Self.release(bt, $0, confirm: confirm) } }
        if confirm { await refresh() }
        if !released {
            Log.write("Flow", "push(\(reason)): release refused — aborting")
            _ = try? await sendToPeer(["action": "cancel"], endpoint: endpoint, timeout: 3)
            return .failure(.init(message: "This Mac couldn't release the devices safely, so nothing was moved. Try again in a few seconds."))
        }
        if abandon { return .success("Released without sending receive (test).") }

        do {
            _ = try await sendToPeer(["action": "receive", "devices": macs], endpoint: endpoint, timeout: 90)
            Log.write("Flow", "push(\(reason)): done")
            return .success("Sent to \(bonjour.peerName ?? "the other Mac").")
        } catch {
            Log.write("Flow", "push(\(reason)): receiver failed (\(error.localizedDescription)) — taking devices back")
            let recovered = await bt.run { [bt] in macs.allSatisfy { Self.acquireAfterRelease(bt, $0) } }
            await refresh()
            return .failure(.init(message: "The other Mac couldn't connect the devices: \(error.localizedDescription)\n"
                                  + (recovered ? "They were reconnected here." : "Reconnecting here failed too; the main Mac will keep retrying.")))
        }
    }

    func pull(reason: String) async -> Result<String, TransferError> {
        guard !busy else { return .failure(.init(message: "A transfer is already in progress.")) }
        guard settings.isConfigured else { return .failure(.init(message: "No device configured. Open Settings.")) }
        busy = true
        defer { busy = false }

        let macs = settings.deviceMACs
        var peerReleased = false
        if let endpoint = bonjour.peerEndpoint {
            do {
                _ = try await sendToPeer(["action": "release", "devices": macs], endpoint: endpoint, timeout: 30)
                peerReleased = true
            } catch PeerClientError.failed(let message) {
                return .failure(.init(message: "The other Mac refused to release the devices: \(message)"))
            } catch {
                Log.write("Flow", "pull(\(reason)): peer unreachable — claiming directly")
            }
        }

        Log.write("Flow", "pull(\(reason)): acquiring (peer released: \(peerReleased))")
        let ok = await bt.run { [bt] in
            macs.allSatisfy { peerReleased ? Self.acquireAfterRelease(bt, $0) : Self.claim(bt, $0) }
        }
        await refresh()
        if ok { return .success("Connected here.") }
        return .failure(.init(message: peerReleased
            ? "The other Mac released the devices but this Mac couldn't connect them. The main Mac will keep retrying."
            : "Couldn't connect. If the other Mac crashed or lost power while holding the trackpad, switch the trackpad off and on, then try again."))
    }

    // MARK: - Bluetooth recipes (run on the Bluetooth thread)

    /// Sender side: unpair while the link is up so the device receives the
    /// Virtual Cable Unplug, forgets this Mac and becomes pairable.
    /// Returns false (and changes nothing) if the unplug can't be delivered.
    @discardableResult
    nonisolated static func release(_ bt: BluetoothManager, _ mac: String, confirm: Bool = true) -> Bool {
        if !bt.isPaired(mac) { return true } // not ours to release
        if !bt.isConnected(mac) {
            bt.connect(mac, timeout: 5) // the unplug only reaches a connected device
        }
        guard bt.isConnected(mac) else {
            Log.write("BT", "release \(mac): not reachable — keeping the pairing")
            return false
        }
        // The unplug travels over the HID channel; unpairing before it is open
        // strands the device (see BluetoothManager.isHIDReady).
        guard bt.settle(mac) else {
            Log.write("BT", "release \(mac): HID channel not ready — refusing to unpair")
            return false
        }
        bt.unpair(mac)
        // Shutdown: macOS kills the app within seconds — tell the receiver now.
        if !confirm { return true }
        // The device drops the link itself within ~1 s when it processed the unplug.
        let prompt = bt.waitFor(timeout: 1.5) { !bt.isConnected(mac) }
        if !prompt { bt.waitFor(timeout: 2) { !bt.isConnected(mac) } }
        Log.write("BT", "release \(mac): " + (prompt ? "unplug acknowledged" : "WARNING slow disconnect — unplug may not have reached the device"))
        return true
    }

    /// Receiver side, right after the peer released: drop any stale record
    /// and pair immediately (host-initiated pairing is silent).
    nonisolated static func acquireAfterRelease(_ bt: BluetoothManager, _ mac: String) -> Bool {
        if bt.isConnected(mac) { return true }
        if bt.isPaired(mac) { bt.unpair(mac) }
        for attempt in 1...6 {
            if pairAndConnect(bt, mac) { return true }
            Log.write("BT", "acquire \(mac): attempt \(attempt) failed")
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    /// Nobody released anything: reconnect with our own key if it is still
    /// valid, otherwise pair if the device is pairable (power-cycled or freshly
    /// unplugged). Never drops our record first — if the device still holds our
    /// key, removing it would strand the device.
    nonisolated static func claim(_ bt: BluetoothManager, _ mac: String) -> Bool {
        if bt.isConnected(mac) { return true }
        if bt.isPaired(mac) {
            bt.connect(mac, timeout: 5)
            if bt.waitFor(timeout: 2, { bt.isConnected(mac) }) { return bt.settle(mac) }
        }
        return pairAndConnect(bt, mac)
    }

    private nonisolated static func pairAndConnect(_ bt: BluetoothManager, _ mac: String) -> Bool {
        guard bt.pair(mac, timeout: 6) == kIOReturnSuccess else { return false }
        if !bt.waitFor(timeout: 3, { bt.isConnected(mac) }) {
            bt.connect(mac, timeout: 8)
            guard bt.waitFor(timeout: 3, { bt.isConnected(mac) }) else { return false }
        }
        // Report success only once the link is stable, so nothing can release
        // (unplug) the device before it is able to process the unplug.
        return bt.settle(mac)
    }

    // MARK: - Requests (peer and local control)

    func handle(_ request: [String: Any], isLocal: Bool) async -> [String: Any] {
        let action = request["action"] as? String ?? ""
        // The peer names the devices it manages; a Mac that has none
        // configured (device never paired here) adopts them.
        if !isLocal, settings.deviceMACs.isEmpty, let macs = request["devices"] as? [String], !macs.isEmpty {
            settings.deviceMACs = macs.map(BluetoothManager.normalize)
            Log.write("State", "adopted devices from peer: \(settings.deviceMACs)")
        }
        switch action {
        case "status":
            await refresh()
            return ok(["name": settings.thisMachineName, "holds": holdsHere, "available": isAvailable,
                       "idle": SystemEvents.idleSeconds(), "busy": isBusy, "role": settings.role.rawValue])

        case "prepare":
            guard settings.isConfigured else { return error("no device configured on \(settings.thisMachineName)") }
            guard !busy else { return error("busy") }
            receivingUntil = Date().addingTimeInterval(60)
            watchForAbandonedHandoff()
            return ok()

        case "receive":
            receiveWatchdog?.cancel()
            busy = true
            defer { busy = false; receivingUntil = .distantPast }
            let macs = settings.deviceMACs
            let success = await bt.run { [bt] in macs.allSatisfy { Self.acquireAfterRelease(bt, $0) } }
            await refresh()
            lastResult = success ? "Received from \(bonjour.peerName ?? "the other Mac")." : "Receiving failed."
            return success ? ok() : error("pairing failed on \(settings.thisMachineName)")

        case "release":
            guard !busy else { return error("busy") }
            busy = true
            defer { busy = false }
            let macs = settings.deviceMACs
            let released = await bt.run { [bt] in macs.allSatisfy { Self.release(bt, $0) } }
            await refresh()
            guard released else { return error("couldn't release the devices safely on \(settings.thisMachineName)") }
            lastResult = "Released to \(bonjour.peerName ?? "the other Mac")."
            return ok()

        case "cancel":
            receiveWatchdog?.cancel()
            receivingUntil = .distantPast
            return ok()

        default:
            guard isLocal else { return error("unknown action: \(action)") }
            return await handleLocal(action, request)
        }
    }

    /// Loopback-only: scripted control for testing over SSH.
    private func handleLocal(_ action: String, _ request: [String: Any]) async -> [String: Any] {
        switch action {
        case "push":
            // abandon: stop after releasing, as if killed by shutdown (tests the receiver watchdog)
            return result(await push(reason: "control", abandon: request["abandon"] as? Bool ?? false))
        case "pull": return result(await pull(reason: "control"))
        case "toggle":
            await refresh()
            return result(holdsHere ? await push(reason: "control") : await pull(reason: "control"))
        case "reconcile":
            await reconcile(reason: "control", arriving: request["arriving"] as? Bool ?? true)
            return ok(["holds": holdsHere])
        case "event":
            // Simulate system events without locking/sleeping the Mac.
            switch request["name"] as? String {
            case "lock": await leaving(reason: "lock(sim)", requirePeerUnlocked: true)
            case "sleep": await leaving(reason: "sleep(sim)", requirePeerUnlocked: false)
            case "arrive": await arriving(reason: "arrive(sim)")
            case "launch": await arriving(reason: "launch")
            case "shutdown": await leaving(reason: "shutdown", requirePeerUnlocked: false)
            default: return error("event name must be lock | sleep | shutdown | arrive | launch")
            }
            return ok(["holds": holdsHere])
        case "auto":
            if let on = request["on"] as? Bool { settings.autoHandoff = on }
            return ok(["auto": settings.autoHandoff])
        case "config":
            if let macs = request["devices"] as? [String] { settings.deviceMACs = macs.map(BluetoothManager.normalize) }
            if let role = (request["role"] as? String).flatMap(MacRole.init) { settings.role = role }
            if let host = request["peerHost"] as? String { settings.peerHost = host }
            return ok(["devices": settings.deviceMACs, "role": settings.role.rawValue, "peerHost": settings.peerHost,
                       "auto": settings.autoHandoff, "peer": bonjour.peerName ?? NSNull()])
        case "log":
            return ok(["lines": Log.tail(request["count"] as? Int ?? 100)])
        case "bt":
            return await debugBluetooth(request)
        default:
            return error("unknown action: \(action)")
        }
    }

    private func debugBluetooth(_ request: [String: Any]) async -> [String: Any] {
        let op = request["op"] as? String ?? ""
        let mac = BluetoothManager.normalize(request["mac"] as? String ?? settings.deviceMACs.first ?? "")
        let timeout = request["timeout"] as? Double ?? 10
        let out: [String: Any] = await bt.run { [bt] in
            var r: [String: Any] = [:]
            switch op {
            case "state": break
            case "connect": r["rc"] = BluetoothManager.describe(bt.connect(mac, timeout: timeout))
            case "disconnect": r["rc"] = BluetoothManager.describe(bt.disconnect(mac))
            case "pair": r["rc"] = BluetoothManager.describe(bt.pair(mac, timeout: timeout))
            case "unpair": bt.unpair(mac)
            case "release": r["ok"] = Self.release(bt, mac)
            case "acquire": r["ok"] = Self.acquireAfterRelease(bt, mac)
            case "claim": r["ok"] = Self.claim(bt, mac)
            case "hid": r["hid"] = bt.hidDevices(); r["hidReady"] = bt.isHIDReady(mac)
            case "paired":
                r["devices"] = bt.pairedDevices().map { ["mac": $0.mac, "name": $0.name, "connected": $0.connected] }
            default: r["error"] = "unknown op"
            }
            r["powered"] = bt.isPoweredOn
            r["paired"] = bt.isPaired(mac)
            r["connected"] = bt.isConnected(mac)
            return r
        }
        await refresh()
        return ok(out)
    }

    private func ok(_ extra: [String: Any] = [:]) -> [String: Any] {
        extra.merging(["status": "ok"]) { $1 }
    }

    private func error(_ message: String) -> [String: Any] {
        ["status": "error", "message": message]
    }

    private func result(_ r: Result<String, TransferError>) -> [String: Any] {
        switch r {
        case .success(let m): return ok(["message": m])
        case .failure(let e): return error(e.message)
        }
    }
}
