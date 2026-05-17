@preconcurrency import Foundation
import Network

final class PeerServer: @unchecked Sendable {
    private let settings: AppSettings
    private let bluetooth: BluetoothManager
    private var listener: NWListener?
    private let btQueue = DispatchQueue(label: "btmanager", qos: .userInitiated)

    init(settings: AppSettings, bluetooth: BluetoothManager) {
        self.settings = settings
        self.bluetooth = bluetooth
    }

    func start() {
        let port = NWEndpoint.Port(integerLiteral: UInt16(settings.serverPort))
        guard let listener = try? NWListener(using: .tcp, on: port) else { return }

        listener.service = NWListener.Service(
            name: settings.thisMachineName,
            type: "_mtconnector._tcp"
        )

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[PeerServer] listener failed: \(error)")
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: .global())
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        receiveMessage(connection)
    }

    private func receiveMessage(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            guard let commandData = data.split(separator: UInt8(ascii: "\n")).first.map({ Data($0) }),
                  let command = try? JSONDecoder().decode(PeerCommand.self, from: commandData) else {
                self.send(PeerResponse(status: "error", message: "Invalid command"), on: connection)
                return
            }

            self.btQueue.async {
                let response = self.execute(command)
                self.send(response, on: connection)
            }
        }
    }

    private func execute(_ command: PeerCommand) -> PeerResponse {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else {
            return PeerResponse(status: "error", message: "Trackpad MAC not configured")
        }

        do {
            switch command.action {
            case "connect":
                try bluetooth.connect(mac: mac)
            case "disconnect":
                try bluetooth.disconnect(mac: mac)
            case "status":
                let connected = bluetooth.isConnected(mac: mac)
                return PeerResponse(status: "ok", message: connected ? "connected" : "disconnected")
            default:
                return PeerResponse(status: "error", message: "Unknown action: \(command.action)")
            }
            return PeerResponse(status: "ok", message: nil)
        } catch {
            return PeerResponse(status: "error", message: error.localizedDescription)
        }
    }

    private func send(_ response: PeerResponse, on connection: NWConnection) {
        guard var data = try? JSONEncoder().encode(response) else {
            connection.cancel()
            return
        }
        data.append(UInt8(ascii: "\n"))
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

