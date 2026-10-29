import Foundation
import Network

/// Wire format: one JSON object per line, request then response, then close.
///   request:  {"action": "...", ...}
///   response: {"status": "ok" | "error", "message": "...", ...}
nonisolated enum Wire {
    /// This Mac's peer name; every response carries the responder's name so a
    /// request that looped back to ourselves is detected.
    nonisolated(unsafe) static var myName = ""

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

    /// Read until the first newline (responses can exceed one TCP segment).
    static func readLine(_ connection: NWConnection, buffer: Data = Data(),
                         completion: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.contains(UInt8(ascii: "\n")) {
                completion(buffer)
            } else if isComplete || error != nil {
                completion(buffer.isEmpty ? nil : buffer)
            } else {
                readLine(connection, buffer: buffer, completion: completion)
            }
        }
    }
}

enum PeerClientError: LocalizedError {
    case unreachable
    case timeout
    case invalidResponse
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "The other Mac is not reachable."
        case .timeout: return "The other Mac did not answer in time."
        case .invalidResponse: return "The other Mac sent an invalid response."
        case .failed(let message): return "The other Mac reported: \(message)"
        }
    }
}

/// Send one request and wait for the response. Throws on transport failure
/// or a `"status": "error"` reply.
nonisolated func sendToPeer(_ request: [String: Any], endpoint: NWEndpoint,
                            timeout: TimeInterval = 5) async throws -> [String: Any] {
    let payload = Wire.encode(request)
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
    guard let response = Wire.decode(raw) else { throw PeerClientError.invalidResponse }
    if let from = response["from"] as? String, from == Wire.myName {
        Log.write("Net", "request looped back to this Mac — treating peer as unreachable")
        throw PeerClientError.unreachable
    }
    if (response["status"] as? String) != "ok" {
        throw PeerClientError.failed(response["message"] as? String ?? "unknown error")
    }
    return response
}
