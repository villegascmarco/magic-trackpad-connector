import Foundation
import Network

/// TCP listener for the peer protocol, advertised over Bonjour as
/// `_mtconnector._tcp`. Requests are handed to `handler` on the main actor
/// together with whether they came from this machine (loopback): local-only
/// actions (manual push/pull, debug Bluetooth primitives) are refused from
/// the network.
nonisolated final class PeerServer: @unchecked Sendable {
    typealias Handler = @MainActor (_ request: [String: Any], _ isLocal: Bool) async -> [String: Any]

    private let port: UInt16
    private let serviceName: String
    private let handler: Handler
    private var listener: NWListener?

    init(port: Int, serviceName: String, handler: @escaping Handler) {
        self.port = UInt16(port)
        self.serviceName = serviceName
        self.handler = handler
    }

    func start() {
        guard let port = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: port) else {
            Log.write("Net", "could not open listener on port \(self.port)")
            return
        }
        listener.service = NWListener.Service(name: serviceName, type: "_mtconnector._tcp")
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Log.write("Net", "listening on :\(self.port)")
            case .failed(let error): Log.write("Net", "listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        Wire.readLine(connection) { [weak self] data in
            guard let self, let data, let request = Wire.decode(data) else {
                connection.cancel()
                return
            }
            let isLocal = Self.isLoopback(connection.currentPath?.remoteEndpoint)
            let handler = self.handler
            nonisolated(unsafe) let req = request
            Task { @MainActor in
                var response = await handler(req, isLocal)
                response["from"] = self.serviceName
                let payload = Wire.encode(response)
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}
