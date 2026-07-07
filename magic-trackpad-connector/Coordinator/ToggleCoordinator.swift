import AppKit
import Network

@MainActor
final class ToggleCoordinator {
    private let settings: AppSettings
    private let bluetooth: BluetoothManager
    private let bonjourService: BonjourService
    private let btQueue = DispatchQueue(label: "toggle.bt", qos: .userInitiated)

    var onStatusChanged: (() -> Void)?
    private(set) var isTrackpadConnected: Bool = false

    private var pollingTimer: Timer?

    // Release mode: this Mac yielded the trackpad — fight off macOS auto-reconnect.
    private var releaseUntil: Date = .distantPast
    private var releaseModeTask: Task<Void, Never>?

    // Claim mode: this Mac received the trackpad — reconnect if the other Mac steals it back.
    private var claimUntil: Date = .distantPast
    private var claimModeTask: Task<Void, Never>?

    init(settings: AppSettings, bluetooth: BluetoothManager, bonjourService: BonjourService) {
        self.settings = settings
        self.bluetooth = bluetooth
        self.bonjourService = bonjourService
    }

    // MARK: - Release / Claim modes

    func enterReleaseMode(duration: TimeInterval = 30) {
        exitClaimMode()
        releaseUntil = Date().addingTimeInterval(duration)
        NSLog("[Coordinator] release mode ON for \(Int(duration))s")
        releaseModeTask?.cancel()
        releaseModeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let mac = self.settings.trackpadMAC
            guard !mac.isEmpty else { return }
            while !Task.isCancelled, Date() < self.releaseUntil {
                try? await Task.sleep(for: .milliseconds(2000))
                guard !Task.isCancelled, Date() < self.releaseUntil else { break }
                let connected = await self.checkIsConnected(mac: mac)
                if connected {
                    NSLog("[Coordinator] release mode: disconnecting macOS auto-reconnect")
                    let bt = self.bluetooth
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        self.btQueue.async { try? bt.disconnect(mac: mac); c.resume() }
                    }
                    self.isTrackpadConnected = false
                    self.onStatusChanged?()
                }
            }
            NSLog("[Coordinator] release mode OFF")
        }
    }

    func enterClaimMode(duration: TimeInterval = 30) {
        exitReleaseMode()
        claimUntil = Date().addingTimeInterval(duration)
        NSLog("[Coordinator] claim mode ON for \(Int(duration))s")
        claimModeTask?.cancel()
        claimModeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let mac = self.settings.trackpadMAC
            guard !mac.isEmpty else { return }
            while !Task.isCancelled, Date() < self.claimUntil {
                try? await Task.sleep(for: .milliseconds(2000))
                guard !Task.isCancelled, Date() < self.claimUntil else { break }
                let connected = await self.checkIsConnected(mac: mac)
                if !connected {
                    NSLog("[Coordinator] claim mode: reconnecting (stolen back by other Mac)")
                    let bt = self.bluetooth
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        // connectSimple: our pairing is fresh here — never unpair
                        // on a transient failure inside the claim loop.
                        self.btQueue.async { try? bt.connectSimple(mac: mac); c.resume() }
                    }
                    await self.refreshConnectionStatus()
                }
            }
            NSLog("[Coordinator] claim mode OFF")
        }
    }

    private func exitReleaseMode() {
        releaseUntil = .distantPast
        releaseModeTask?.cancel()
        releaseModeTask = nil
    }

    private func exitClaimMode() {
        claimUntil = .distantPast
        claimModeTask?.cancel()
        claimModeTask = nil
    }

    // MARK: - Lifecycle

    func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshConnectionStatus()
            }
        }
    }

    func connectOnLaunch() async {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else { return }

        // Already here — nothing to do.
        if await checkIsConnected(mac: mac) {
            await refreshConnectionStatus()
            return
        }

        // Wait briefly for Bonjour to discover the peer before deciding whether
        // to ask them to release first.
        try? await Task.sleep(for: .seconds(2))

        // If peer is online, politely ask it to disconnect before we try to grab
        // the trackpad. Ignore failures — we attempt the connect regardless.
        if let endpoint = bonjourService.peerEndpoint {
            _ = try? await sendCommandToPeer(action: "disconnect", endpoint: endpoint)
            try? await Task.sleep(for: .milliseconds(800))
        }

        let bt = bluetooth
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            btQueue.async {
                try? bt.connect(mac: mac)
                continuation.resume()
            }
        }
        await refreshConnectionStatus()
    }

    // MARK: - Toggle

    func toggle() async {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else {
            showError("Trackpad not detected yet.\nOpen Settings — the app will scan automatically.")
            return
        }

        let connected = await checkIsConnected(mac: mac)
        let peerEndpoint = bonjourService.peerEndpoint

        if connected {
            // Trackpad is here — send to peer (requires peer online)
            guard let endpoint = peerEndpoint else {
                showError("Cannot send trackpad: the other Mac is not reachable.\nMake sure the app is running there too.")
                return
            }
            await sendTrackpadToPeer(mac: mac, peerEndpoint: endpoint)
        } else if let endpoint = peerEndpoint {
            // Trackpad is not here and peer is online — take it from peer
            await bringTrackpadHere(mac: mac, peerEndpoint: endpoint)
        } else {
            // Trackpad is not connected anywhere — just connect locally
            await connectLocally(mac: mac)
        }

        await refreshConnectionStatus()
    }

    func connectLocally() async {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else { return }
        await connectLocally(mac: mac)
        await refreshConnectionStatus()
    }

    private func connectLocally(mac: String) async {
        // User explicitly requesting local connect — cancel any active mode.
        exitReleaseMode()
        exitClaimMode()
        let bt = bluetooth
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            btQueue.async {
                try? bt.connect(mac: mac)
                continuation.resume()
            }
        }
    }

    // MARK: - Transfer helpers

    private func sendTrackpadToPeer(mac: String, peerEndpoint: NWEndpoint) async {
        // Pre-flight: verify peer is reachable AND ready to receive before
        // touching the local connection. Nothing is changed if this fails.
        do {
            _ = try await sendCommandToPeer(action: "ready", endpoint: peerEndpoint)
        } catch {
            showError("The other Mac is not ready to receive the trackpad:\n\(error.localizedDescription)\n\nNo changes were made.")
            return
        }

        // Disconnect locally — Bluetooth only allows one host at a time.
        let bt = bluetooth
        let disconnected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            btQueue.async {
                do {
                    try bt.disconnect(mac: mac)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
        guard disconnected else {
            showError("Could not disconnect trackpad from this Mac.\n\nNo changes were made.")
            return
        }

        // blueutil --disconnect returns before the BT hardware has fully torn down
        // the link. Poll isConnected until the device is genuinely gone, then add a
        // small extra buffer so Mac B doesn't race with the link teardown.
        NSLog("[Coordinator] disconnect issued, polling until device is fully released")
        for attempt in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            if !(await checkIsConnected(mac: mac)) {
                NSLog("[Coordinator] device released after \((attempt + 1) * 300)ms")
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(500))

        do {
            _ = try await sendCommandToPeer(action: "connect", endpoint: peerEndpoint)
            // Enter release mode: macOS will try to auto-reconnect here; keep fighting it off.
            enterReleaseMode()
        } catch {
            // Rollback: reconnect locally so the trackpad isn't stranded.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                btQueue.async { try? bt.connect(mac: mac); continuation.resume() }
            }
            showError("The other Mac failed to connect the trackpad.\nReconnected here as fallback.\n\n\(error.localizedDescription)")
        }
    }

    private func bringTrackpadHere(mac: String, peerEndpoint: NWEndpoint) async {
        // Tell the peer to release the trackpad.
        do {
            _ = try await sendCommandToPeer(action: "disconnect", endpoint: peerEndpoint)
            NSLog("[Coordinator] peer released trackpad, waiting for BT stack to settle")
        } catch {
            showError("Could not disconnect trackpad on the other Mac:\n\(error.localizedDescription)\n\nNo changes were made.")
            return
        }

        // Magic Trackpad can take up to ~1.5s to start advertising after disconnect.
        try? await Task.sleep(for: .milliseconds(1500))

        let bt = bluetooth
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            btQueue.async {
                do {
                    try bt.connect(mac: mac)
                    continuation.resume(returning: true)
                } catch {
                    NSLog("[Coordinator] local connect failed after peer release: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
        if success {
            // Enter claim mode: the peer's macOS may steal the trackpad back; keep reclaiming.
            enterClaimMode()
        } else {
            showError("The trackpad was released by the other Mac but this Mac could not connect.\nMake sure the trackpad is charged and in range, then try again.")
        }
    }

    // MARK: - Internal helpers

    private func checkIsConnected(mac: String) async -> Bool {
        let bt = bluetooth
        return await withCheckedContinuation { continuation in
            btQueue.async {
                continuation.resume(returning: bt.isConnected(mac: mac))
            }
        }
    }

    func refreshConnectionStatus() async {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else {
            isTrackpadConnected = false
            onStatusChanged?()
            return
        }
        let connected = await checkIsConnected(mac: mac)
        isTrackpadConnected = connected
        onStatusChanged?()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Magic Trackpad Connector"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
