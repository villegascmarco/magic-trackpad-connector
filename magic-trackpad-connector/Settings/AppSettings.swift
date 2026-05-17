import Foundation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var trackpadMAC: String {
        didSet { defaults.set(trackpadMAC, forKey: "trackpadMAC") }
    }

    var trackpadName: String {
        didSet { defaults.set(trackpadName, forKey: "trackpadName") }
    }

    var thisMachineName: String {
        didSet { defaults.set(thisMachineName, forKey: "thisMachineName") }
    }

    var serverPort: Int {
        didSet { defaults.set(serverPort, forKey: "serverPort") }
    }

    var isTrackpadConfigured: Bool { !trackpadMAC.isEmpty }

    private init() {
        trackpadMAC = defaults.string(forKey: "trackpadMAC") ?? ""
        trackpadName = defaults.string(forKey: "trackpadName") ?? ""
        thisMachineName = defaults.string(forKey: "thisMachineName")
            ?? Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        serverPort = defaults.integer(forKey: "serverPort").nonZero ?? 7890
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
