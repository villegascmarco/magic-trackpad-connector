import CryptoKit
import Foundation
import Network

/// TCP listener for the peer protocol, advertised over Bonjour as
/// `_mtconnector._tcp`. Requests are handed to `handler` on the main actor
/// together with whether they came from this machine (loopback): local-only
/// actions (manual push/pull, debug Bluetooth primitives) are refused from
/// the network. Network requests must be sealed with the pairing code
/// (see `Wire`); anything else is refused before reaching the handler.
nonisolated final class PeerServer: @unchecked Sendable {
    typealias Handler = @MainActor (_ request: [String: Any], _ isLocal: Bool) async -> [String: Any]

    private let port: UInt16
    private let serviceName: String
    private let handler: Handler
    private var listener: NWListener?
    private let replayGuard = ReplayGuard()
    private let logLock = NSLock()
    private var lastLogged: [String: Date] = [:]
    /// Open network connections per remote host, so one host can't crowd out
    /// the other Mac; each must deliver its request line within `readDeadline`.
    /// Loopback (ctl.sh) is not limited.
    private var open: [String: Int] = [:]
    private static let maxOpen = 16
    private static let maxOpenPerHost = 4
    private static let readDeadline: TimeInterval = 2

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
        let host = Self.isLoopback(connection.endpoint) ? nil : Self.hostKey(connection.endpoint)
        // Peers connect over IPv4 only (see Wire.parameters); one host can
        // hold any number of IPv6 addresses and would get around the per-host cap.
        if host != nil, case .hostPort(.ipv6, _) = connection.endpoint {
            connection.cancel()
            return
        }
        if let host {
            let admitted = logLock.withLock {
                guard open.values.reduce(0, +) < Self.maxOpen, open[host, default: 0] < Self.maxOpenPerHost else { return false }
                open[host, default: 0] += 1
                return true
            }
            guard admitted else { connection.cancel(); return }
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: connection.cancel()
            case .cancelled:
                guard let self, let host else { return }
                self.logLock.withLock {
                    self.open[host, default: 1] -= 1
                    if self.open[host] == 0 { self.open[host] = nil }
                }
            default: break
            }
        }
        connection.start(queue: .global())
        let readLock = NSLock()
        nonisolated(unsafe) var read = false
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.readDeadline) {
            if !readLock.withLock({ read }) { connection.cancel() }
        }
        Wire.readLine(connection) { [weak self] data in
            readLock.withLock { read = true }
            guard let self, let data, let message = Wire.decode(data) else {
                connection.cancel()
                return
            }
            let isLocal = Self.isLoopback(connection.currentPath?.remoteEndpoint)
            var request = message
            var seal: (key: SymmetricKey, nonce: String)?
            if Wire.isSealed(message) {
                switch self.verify(message) {
                case .success(let verified): (request, seal) = verified
                case .failure(let reason): return self.refuse(connection, reason.message)
                }
            } else if !isLocal {
                return self.refuse(connection, Wire.key == nil ? "not paired" : "unsigned request")
            }
            let handler = self.handler
            nonisolated(unsafe) let req = request
            Task { @MainActor in
                var response = await handler(req, isLocal)
                response["from"] = self.serviceName
                if let seal {
                    response["re"] = seal.nonce
                    response = Wire.seal(response, key: seal.key)
                }
                let payload = Wire.encode(response)
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private struct Refusal: Error { let message: String }

    private func verify(_ envelope: [String: Any]) -> Result<([String: Any], (key: SymmetricKey, nonce: String)), Refusal> {
        guard let key = Wire.key else { return .failure(Refusal(message: "not paired")) }
        guard let request = Wire.open(envelope, key: key) else { return .failure(Refusal(message: "bad signature")) }
        guard let from = request["from"] as? String, !from.isEmpty else { return .failure(Refusal(message: "bad signature")) }
        guard from != serviceName, from != Wire.myName else { return .failure(Refusal(message: "looped back")) }
        let nonce = request["nonce"] as? String ?? ""
        guard replayGuard.accept(nonce: nonce, ts: request["ts"] as? Double ?? 0) else {
            return .failure(Refusal(message: "stale or replayed request"))
        }
        return .success((request, (key, nonce)))
    }

    /// Plain error reply; the handler never sees the request.
    private func refuse(_ connection: NWConnection, _ reason: String) {
        let now = Date()
        let shouldLog = logLock.withLock {
            guard now.timeIntervalSince(lastLogged[reason] ?? .distantPast) > 300 else { return false }
            lastLogged[reason] = now
            return true
        }
        if shouldLog {
            Log.write("Net", "refused request from \(connection.endpoint): \(reason)")
        }
        let payload = Wire.encode(["status": "error", "message": reason])
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func hostKey(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        return "\(host)"
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
