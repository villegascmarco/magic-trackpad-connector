import CryptoKit
import Foundation
import Network

/// Wire format: one JSON object per line, request then response, then close.
///   request:  {"action": "...", ...}
///   response: {"status": "ok" | "error", "message": "...", ...}
/// Between Macs both travel sealed with the shared pairing code:
///   {"body": "<request or response JSON>", "mac": "<hex HMAC-SHA256(key, body)>"}
/// Sealed requests carry `ts` (unix seconds) and a random `nonce`; the sealed
/// response echoes it as `re`. Plain JSON is accepted from loopback only.
nonisolated enum Wire {
    /// This Mac's peer name; every response carries the responder's name so a
    /// request that looped back to ourselves is detected.
    nonisolated(unsafe) static var myName = ""

    /// HMAC key derived from the pairing code; nil = no code set (not paired).
    static var key: SymmetricKey? {
        get { keyLock.withLock { storedKey } }
        set { keyLock.withLock { storedKey = newValue } }
    }
    private nonisolated(unsafe) static var storedKey: SymmetricKey?
    private static let keyLock = NSLock()

    /// Case, spaces and dashes don't matter, so the code can be typed loosely.
    /// Shorter codes could be guessed offline from one captured message.
    static let minPairingCodeLength = 12

    /// Letters and digits only, uppercased; "" if too short to be used.
    static func normalizePairingCode(_ code: String) -> String {
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        return normalized.count >= minPairingCodeLength ? normalized : ""
    }

    static func setPairingCode(_ code: String) {
        let normalized = normalizePairingCode(code)
        key = normalized.isEmpty ? nil : HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalized.utf8)),
            salt: Data("mtconnector-v1".utf8), info: Data("peer-hmac".utf8), outputByteCount: 32)
    }

    static func isSealed(_ message: [String: Any]) -> Bool {
        message["body"] != nil || message["mac"] != nil
    }

    static func seal(_ object: [String: Any], key: SymmetricKey) -> [String: Any] {
        let body = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        return ["body": body, "mac": Data(mac).map { String(format: "%02x", $0) }.joined()]
    }

    /// The sealed object, or nil if the MAC doesn't match (constant-time check).
    static func open(_ envelope: [String: Any], key: SymmetricKey) -> [String: Any]? {
        guard let body = envelope["body"] as? String, let hex = envelope["mac"] as? String,
              let mac = Data(hex: hex),
              HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(body.utf8), using: key) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }

    static func nonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// IPv4 only: the MDM-managed MacBook advertises ::1 and fe80::1 as its
    /// own addresses over Bonjour, and Network.framework prefers IPv6 — so
    /// "connect to the peer" silently connected to this Mac's own loopback.
    static func parameters() -> NWParameters {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        return params
    }

    static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func decode(_ data: Data) -> [String: Any]? {
        let line = data.split(separator: UInt8(ascii: "\n")).first.map { Data($0) } ?? data
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// Longest line accepted; messages are a few hundred bytes.
    static let maxLine = 65536

    /// Read until the first newline (responses can exceed one TCP segment).
    /// Gives nil past `maxLine`, so a peer can't make us buffer without end.
    static func readLine(_ connection: NWConnection, buffer: Data = Data(),
                         completion: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.contains(UInt8(ascii: "\n")) {
                completion(buffer)
            } else if buffer.count > maxLine {
                completion(nil)
            } else if isComplete || error != nil {
                completion(buffer.isEmpty ? nil : buffer)
            } else {
                readLine(connection, buffer: buffer, completion: completion)
            }
        }
    }
}

/// Requests seen recently, so a captured request can't be played back.
nonisolated final class ReplayGuard: @unchecked Sendable {
    /// Both Macs' clocks must agree within this.
    static let window: TimeInterval = 120
    private let lock = NSLock()
    private var seen: [String: Date]
    /// Persisted so a relaunch doesn't reopen the window for captured requests.
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let stored = defaults?.dictionary(forKey: "seenNonces") as? [String: Double] ?? [:]
        seen = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// True once per nonce, and only for requests stamped within the window.
    func accept(nonce: String, ts: Double, now: Date = Date()) -> Bool {
        guard !nonce.isEmpty, abs(now.timeIntervalSince1970 - ts) <= Self.window else { return false }
        return lock.withLock {
            // A replay must also be within the window of its stamp, so entries
            // older than twice the window can't match anything acceptable.
            seen = seen.filter { now.timeIntervalSince($0.value) <= 2 * Self.window }
            guard seen[nonce] == nil else { return false }
            seen[nonce] = now
            defaults?.set(seen.mapValues(\.timeIntervalSince1970), forKey: "seenNonces")
            return true
        }
    }
}

private extension Data {
    nonisolated init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

enum PeerClientError: LocalizedError {
    case notPaired
    case unreachable
    case timeout
    case invalidResponse
    case rejected(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Set the same pairing code on both Macs (Settings → Network)."
        case .rejected(let reason):
            return "The other Mac ignored the request (\(reason)). Use the same pairing code on both Macs and check that their clocks are set automatically."
        case .unreachable: return "The other Mac is not reachable."
        case .timeout: return "The other Mac did not answer in time."
        case .invalidResponse: return "The other Mac sent an invalid response."
        case .failed(let message): return "The other Mac reported: \(message)"
        }
    }

    /// The peer answered but refused to act on our request (pairing code or clock mismatch).
    var isRejection: Bool {
        if case .rejected = self { return true }
        return false
    }
}

/// Send one sealed request and wait for the response. Throws on transport
/// failure, an unauthenticated reply, or a `"status": "error"` reply.
nonisolated func sendToPeer(_ request: [String: Any], endpoint: NWEndpoint,
                            timeout: TimeInterval = 5) async throws -> [String: Any] {
    guard let key = Wire.key else { throw PeerClientError.notPaired }
    let nonce = Wire.nonce()
    var body = request
    body["ts"] = Date().timeIntervalSince1970
    body["nonce"] = nonce
    // Both Macs share one key: naming the sender lets each refuse its own
    // requests bounced back at it.
    body["from"] = Wire.myName
    let payload = Wire.encode(Wire.seal(body, key: key))
    let raw: Data = try await withCheckedThrowingContinuation { continuation in
        let connection = NWConnection(to: endpoint, using: Wire.parameters())
        let lock = NSLock()
        nonisolated(unsafe) var finished = false
        let finish: @Sendable (Result<Data, Error>) -> Void = { result in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            connection.cancel()
            continuation.resume(with: result)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.failure(PeerClientError.timeout))
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error { finish(.failure(error)); return }
                    Wire.readLine(connection) { data in
                        if let data { finish(.success(data)) } else { finish(.failure(PeerClientError.invalidResponse)) }
                    }
                })
            case .failed, .cancelled:
                finish(.failure(PeerClientError.unreachable))
            case .waiting:
                // No route / connection refused: don't sit out the whole timeout.
                finish(.failure(PeerClientError.unreachable))
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
    guard let message = Wire.decode(raw) else { throw PeerClientError.invalidResponse }
    // A plain reply means the peer refused us before doing anything.
    guard Wire.isSealed(message) else {
        let reason = message["message"] as? String ?? "unsigned reply"
        if reason == "looped back" {
            Log.write("Net", "request looped back to this Mac — treating peer as unreachable")
            throw PeerClientError.unreachable
        }
        throw PeerClientError.rejected(reason)
    }
    guard let response = Wire.open(message, key: key), response["re"] as? String == nonce else {
        throw PeerClientError.invalidResponse
    }
    if let from = response["from"] as? String, from == Wire.myName {
        Log.write("Net", "request looped back to this Mac — treating peer as unreachable")
        throw PeerClientError.unreachable
    }
    if (response["status"] as? String) != "ok" {
        throw PeerClientError.failed(response["message"] as? String ?? "unknown error")
    }
    return response
}
