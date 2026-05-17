@preconcurrency import Foundation
@preconcurrency import Dispatch
import Network

enum PeerClientError: LocalizedError {
    case peerUnreachable
    case timeout
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .peerUnreachable: return "Peer machine is not reachable."
        case .timeout: return "Connection to peer timed out."
        case .commandFailed(let msg): return "Peer reported an error: \(msg)"
        case .invalidResponse: return "Received an invalid response from peer."
        }
    }
}

nonisolated func sendCommandToPeer(action: String, endpoint: NWEndpoint, timeout: TimeInterval = 5) async throws -> PeerResponse {
    return try await withCheckedThrowingContinuation { continuation in
        let connection = NWConnection(to: endpoint, using: .tcp)
        var didResume = false

        let resume: (Result<PeerResponse, Error>) -> Void = { result in
            guard !didResume else { return }
            didResume = true
            connection.cancel()
            continuation.resume(with: result)
        }

        let timeoutWork = DispatchWorkItem {
            resume(.failure(PeerClientError.timeout))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                timeoutWork.cancel()
                guard var data = try? JSONEncoder().encode(PeerCommand(action: action)) else {
                    resume(.failure(PeerClientError.invalidResponse))
                    return
                }
                data.append(UInt8(ascii: "\n"))

                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        resume(.failure(error))
                        return
                    }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        if let error {
                            resume(.failure(error))
                            return
                        }
                        guard let data,
                              let responseData = data.split(separator: UInt8(ascii: "\n")).first.map({ Data($0) }),
                              let response = try? JSONDecoder().decode(PeerResponse.self, from: responseData) else {
                            resume(.failure(PeerClientError.invalidResponse))
                            return
                        }
                        if response.status == "ok" {
                            resume(.success(response))
                        } else {
                            resume(.failure(PeerClientError.commandFailed(response.message ?? "unknown error")))
                        }
                    }
                })
            case .failed, .cancelled:
                timeoutWork.cancel()
                resume(.failure(PeerClientError.peerUnreachable))
            default:
                break
            }
        }

        connection.start(queue: .global())
    }
}
