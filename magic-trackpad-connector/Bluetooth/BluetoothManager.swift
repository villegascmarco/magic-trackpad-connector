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
        var lastError: Error?
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1.0) }
            NSLog("[BT] connect attempt \(attempt + 1)/5 for \(mac)")
            do {
                try run(args: ["--connect", mac])
                NSLog("[BT] connect succeeded (blueutil exit 0)")
                return
            } catch {
                lastError = error
                NSLog("[BT] connect attempt failed: \(error.localizedDescription)")
                // blueutil sometimes exits non-zero even though the connection
                // went through — check the actual state before retrying.
                if isConnected(mac: mac) {
                    NSLog("[BT] isConnected=true despite non-zero exit — treating as success")
                    return
                }
            }
        }
        NSLog("[BT] all connect attempts exhausted")
        throw lastError!
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
