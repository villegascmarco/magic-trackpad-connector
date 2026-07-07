import Foundation

final class BluetoothManager: @unchecked Sendable {
    static let shared = BluetoothManager()

    private init() {}

    nonisolated var isAvailable: Bool { blueutilPath != nil }

    private nonisolated var blueutilPath: String? {
        let candidates = ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated func connect(mac: String) throws {
        NSLog("[BT] connect \(mac)")
        // Explicit connect means this Mac wants to be a functioning host again.
        setConnectable(true)
        // Fast path: our stored link key is still valid on the trackpad.
        // --wait-connect avoids hammering the device with repeated requests,
        // which triggers its per-host backoff.
        _ = try? run(args: ["--connect", mac]) // ok if this exits non-zero
        do {
            try run(args: ["--wait-connect", mac, "5"])
            NSLog("[BT] connect confirmed")
            return
        } catch {
            NSLog("[BT] connect timed out — link key likely stale (trackpad re-paired with the other Mac), falling back to re-pair")
        }
        try repairPairingAndConnect(mac: mac)
    }

    /// Plain connect with no re-pair fallback. For claim mode, where the link
    /// key is known-fresh and an unpair on a transient failure would be harmful.
    nonisolated func connectSimple(mac: String) throws {
        NSLog("[BT] connectSimple \(mac)")
        _ = try? run(args: ["--connect", mac])
        try run(args: ["--wait-connect", mac, "10"])
        NSLog("[BT] connect confirmed")
    }

    /// Magic devices store a single link key: once the trackpad pairs with the
    /// other Mac, this Mac's key is invalidated and every connect attempt is
    /// silently rejected. Unpair + pair (Just Works SSP, no PIN) mints a fresh
    /// key — it is the only way to get the device back without user action.
    private nonisolated func repairPairingAndConnect(mac: String) throws {
        _ = try? run(args: ["--unpair", mac])
        Thread.sleep(forTimeInterval: 1.0)
        try pairLoop(mac: mac, attempts: 4, gap: 2.0)
    }

    /// Pair immediately after the peer released the trackpad via handoff.
    ///
    /// Speed matters here: the trackpad, freshly unplugged, actively tries to
    /// connect to Macs it remembers. A device-initiated connection from an
    /// unpaired device makes macOS pop the "Connection Request" dialog, while
    /// a host-initiated --pair (Just Works) completes silently — so skip the
    /// --connect fast path and start pairing right away, retrying quickly.
    nonisolated func pairAfterHandoff(mac: String) throws {
        NSLog("[BT] pairAfterHandoff \(mac)")
        // Keep incoming connections OFF until pairing completes: the hunting
        // trackpad's device-initiated connect pops the Connection Request
        // dialog on the receiver too. Host-initiated pairing works without
        // local page scan, and the pair loop connects host-initiated after.
        setConnectable(false)
        _ = try? run(args: ["--unpair", mac]) // drop our stale record; local-only
        try pairLoop(mac: mac, attempts: 6, gap: 1.0)
        // Restore only on success — the trackpad is bound to us now, so its
        // incoming connections are trusted. On failure we stay dark (the
        // trackpad is still hunting) and the 30 s failsafe restores us.
        setConnectable(true)
    }

    private nonisolated func pairLoop(mac: String, attempts: Int, gap: TimeInterval) throws {
        var lastError: Error?
        for attempt in 1...attempts {
            NSLog("[BT] pair attempt \(attempt)/\(attempts)")
            do {
                try run(args: ["--pair", mac])
                _ = try? run(args: ["--connect", mac])
                try run(args: ["--wait-connect", mac, "10"])
                NSLog("[BT] paired and connected")
                return
            } catch {
                lastError = error
                NSLog("[BT] pair attempt \(attempt) failed: \(error.localizedDescription)")
                // 0x02 (No Connection) here usually means the trackpad hasn't
                // entered pairing mode yet — give it a moment and retry.
                Thread.sleep(forTimeInterval: gap)
            }
        }
        throw lastError ?? BTError.commandFailed(1, "re-pairing failed")
    }

    /// Toggle whether this Mac accepts incoming Bluetooth connections.
    /// Turned off while the freshly-unplugged trackpad hunts for a host, so
    /// its device-initiated attempts cannot pop the macOS "Connection Request"
    /// dialog (accepting one on the wrong Mac breaks the transfer).
    ///
    /// Every OFF arms a 30 s failsafe that turns it back ON, so no failure
    /// path (peer vanished, pairing gave up, app quit mid-transfer) can leave
    /// the Mac permanently invisible to its other Bluetooth devices.
    nonisolated func setConnectable(_ on: Bool) {
        NSLog("[BT] connectable \(on ? "1" : "0")")
        _ = try? run(args: ["--connectable", on ? "1" : "0"])
        if !on {
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [self] in
                setConnectable(true)
            }
        }
    }

    /// Release the trackpad for handoff to the other Mac.
    ///
    /// The trackpad erases its own pairing and enters pairing mode ONLY when
    /// the unpair happens while the link is up — macOS then sends the HID
    /// Virtual Cable Unplug to the device (same as "Forget This Device").
    /// A plain --disconnect leaves the trackpad holding this Mac's key, and it
    /// will then refuse pairing from the other Mac with 0x02 (No Connection).
    nonisolated func releaseForHandoff(mac: String) {
        if !isConnected(mac: mac) {
            NSLog("[BT] handoff: not connected — connecting first so the virtual cable unplug reaches the device")
            _ = try? run(args: ["--connect", mac])
            _ = try? run(args: ["--wait-connect", mac, "5"])
        }
        // Refuse incoming connections BEFORE the unpair: the trackpad starts
        // hunting for a host the instant the unplug lands, and a reconnect
        // attempt that sneaks in pops the macOS Connection Request dialog.
        // Page-scan off does not affect the established link, so the unplug
        // still goes through. Restored when release mode ends (and on launch).
        setConnectable(false)
        let wasConnected = isConnected(mac: mac)
        NSLog("[BT] handoff: unpairing (link up: \(wasConnected)) — trackpad should erase its pairing and become pairable")
        _ = try? run(args: ["--unpair", mac])
        if wasConnected {
            waitForDisconnect(mac: mac, timeout: 3)
        }
    }

    nonisolated func waitForDisconnect(mac: String, timeout: Int = 6) {
        NSLog("[BT] waiting for \(mac) to fully disconnect (max \(timeout)s)")
        _ = try? run(args: ["--wait-disconnect", mac, "\(timeout)"])
        NSLog("[BT] disconnect confirmed")
    }

    nonisolated func disconnect(mac: String) throws {
        NSLog("[BT] disconnect \(mac)")
        try run(args: ["--disconnect", mac])
    }

    nonisolated func isConnected(mac: String) -> Bool {
        let output = (try? runOutput(args: ["--is-connected", mac])) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    nonisolated func findMagicTrackpad() throws -> (mac: String, name: String)? {
        let devices = try pairedDevices()
        return devices.first { $0.name.localizedCaseInsensitiveContains("trackpad") }
    }

    nonisolated func pairedDevices() throws -> [(mac: String, name: String)] {
        let output = try runOutput(args: ["--paired", "--format", "json"])
        guard let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { obj in
            guard let rawMac = obj["address"] as? String,
                  let name = obj["name"] as? String else { return nil }
            let mac = rawMac.replacingOccurrences(of: "-", with: ":")
            return (mac: mac, name: name)
        }
    }

    @discardableResult
    private nonisolated func run(args: [String]) throws -> Int32 {
        guard let path = blueutilPath else { throw BTError.blueutilNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("[BT] blueutil \(args.joined(separator: " ")) → exit \(status): \(errMsg)")
            throw BTError.commandFailed(status, errMsg)
        }
        return status
    }

    private nonisolated func runOutput(args: [String]) throws -> String {
        guard let path = blueutilPath else { throw BTError.blueutilNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum BTError: LocalizedError {
    case blueutilNotFound
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .blueutilNotFound:
            return "blueutil not found. Install it with: brew install blueutil"
        case .commandFailed(let code, let msg):
            return msg.isEmpty
                ? "blueutil command failed (exit \(code))"
                : "blueutil command failed (exit \(code)): \(msg)"
        }
    }
}
