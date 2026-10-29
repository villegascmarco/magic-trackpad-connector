import Foundation
import Network

@Observable
@MainActor
final class BonjourService {
    private let settings: AppSettings
    private var browser: NWBrowser?

    private(set) var peerName: String?
    private var discoveredEndpoint: NWEndpoint?
    var isPeerDiscovered: Bool { discoveredEndpoint != nil }

    /// Bonjour result first, else the manually configured host.
    var peerEndpoint: NWEndpoint? {
        if let discoveredEndpoint { return discoveredEndpoint }
        let host = settings.peerHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(settings.serverPort)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    var onPeerChanged: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        let browser = NWBrowser(for: .bonjour(type: "_mtconnector._tcp", domain: nil), using: .tcp)
        let myName = settings.thisMachineName

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peer = results.first { result in
                if case .service(let name, _, _, _) = result.endpoint { return name != myName }
                return false
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let before = self.peerName
                if let peer, case .service(let name, _, _, _) = peer.endpoint {
                    self.peerName = name
                    self.discoveredEndpoint = peer.endpoint
                } else {
                    self.peerName = nil
                    self.discoveredEndpoint = nil
                }
                if before != self.peerName {
                    Log.write("Net", "peer \(self.peerName.map { "found: \($0)" } ?? "lost")")
                }
                self.onPeerChanged?()
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.write("Net", "browser failed: \(error)")
            }
        }
        browser.start(queue: .global())
        self.browser = browser
    }
}
