import Foundation

enum MacRole: String, CaseIterable {
    /// The orchestrator: takes the devices whenever nobody else has them.
    case primary
    case secondary
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Bluetooth addresses (aa-bb-cc-dd-ee-ff) of the devices moved together.
    var deviceMACs: [String] {
        didSet { defaults.set(deviceMACs, forKey: "deviceMACs") }
    }

    var deviceNames: [String: String] {
        didSet { defaults.set(deviceNames, forKey: "deviceNames") }
    }

    var role: MacRole {
        didSet { defaults.set(role.rawValue, forKey: "role") }
    }

    /// Lock/sleep/shutdown handoff, startup claim and orchestrator fallback.
    var autoHandoff: Bool {
        didSet { defaults.set(autoHandoff, forKey: "autoHandoff") }
    }

    var thisMachineName: String {
        didSet { defaults.set(thisMachineName, forKey: "thisMachineName") }
    }

    /// Optional fallback (e.g. "other-mac.local") when Bonjour can't see the peer.
    var peerHost: String {
        didSet { defaults.set(peerHost, forKey: "peerHost") }
    }

    var serverPort: Int {
        didSet { defaults.set(serverPort, forKey: "serverPort") }
    }

    var isConfigured: Bool { !deviceMACs.isEmpty }

    func displayName(_ mac: String) -> String {
        deviceNames[mac] ?? mac
    }

    private init() {
        var macs = defaults.stringArray(forKey: "deviceMACs") ?? []
        var names = (defaults.dictionary(forKey: "deviceNames") as? [String: String]) ?? [:]
        // Migrate the single-trackpad setting of earlier versions.
        if macs.isEmpty, let legacy = defaults.string(forKey: "trackpadMAC"), !legacy.isEmpty {
            let mac = BluetoothManager.normalize(legacy)
            macs = [mac]
            names[mac] = defaults.string(forKey: "trackpadName")
        }
        deviceMACs = macs
        deviceNames = names
        role = MacRole(rawValue: defaults.string(forKey: "role") ?? "") ?? .secondary
        autoHandoff = defaults.object(forKey: "autoHandoff") as? Bool ?? true
        thisMachineName = defaults.string(forKey: "thisMachineName")
            ?? Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        peerHost = defaults.string(forKey: "peerHost") ?? ""
        serverPort = defaults.integer(forKey: "serverPort").nonZero ?? 7890
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
