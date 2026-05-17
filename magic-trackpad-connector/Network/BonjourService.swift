import Foundation
import Network

@Observable
@MainActor
final class BonjourService {
    private let settings: AppSettings
    private var browser: NWBrowser?

    private(set) var peerName: String?
    private(set) var peerEndpoint: NWEndpoint?
    var isPeerOnline: Bool { peerEndpoint != nil }

    var onPeerChanged: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_mtconnector._tcp", domain: nil),
            using: .tcp
        )

        // Capture before the Sendable closure to avoid crossing the @MainActor boundary.
        let myName = settings.thisMachineName

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peer = results.first(where: { result in
                if case .service(let name, _, _, _) = result.endpoint {
                    return name != myName
                }
                return false
            })

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let peer {
                    if case .service(let name, _, _, _) = peer.endpoint {
                        self.peerName = name
                    }
                    self.peerEndpoint = peer.endpoint
                } else {
                    self.peerName = nil
                    self.peerEndpoint = nil
                }
                self.onPeerChanged?()
            }
        }

        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[BonjourService] browser failed: \(error)")
            }
        }

        browser.start(queue: .global())
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peerName = nil
        peerEndpoint = nil
    }
}
