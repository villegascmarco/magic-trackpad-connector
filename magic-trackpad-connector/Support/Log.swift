import Foundation

/// NSLog + an in-memory ring buffer (served over the loopback control port as
/// the `log` action, so both Macs can be inspected over SSH) + a log file at
/// ~/Library/Logs/MagicTrackpadConnector.log.
nonisolated enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ring: [String] = []
    private static let maxLines = 2000

    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MagicTrackpadConnector.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ tag: String, _ message: String) {
        NSLog("[%@] %@", tag, message)
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)"
        ring.append(line)
        if ring.count > maxLines { ring.removeFirst(ring.count - maxLines) }
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    static func tail(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.suffix(count))
    }
}
