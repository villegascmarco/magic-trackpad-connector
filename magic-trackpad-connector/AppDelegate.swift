import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var peerServer: PeerServer!
    private var bonjourService: BonjourService!
    private var systemEvents: SystemEvents!
    private var coordinator: HandoffCoordinator!
    private var statusBarController: StatusBarController!
    private var hotkey: Hotkey!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let settings = AppSettings.shared
        Log.write("App", "launch — role \(settings.role.rawValue), devices \(settings.deviceMACs), auto \(settings.autoHandoff)")

        // Open at login by default, once; afterwards Settings → Open at Login decides.
        if !UserDefaults.standard.bool(forKey: "didRegisterLoginItem") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didRegisterLoginItem")
        }

        if !settings.isConfigured { autoDetectDevices(settings) }
        fillMissingNames(settings)

        Wire.myName = settings.thisMachineName
        bonjourService = BonjourService(settings: settings)
        systemEvents = SystemEvents()
        coordinator = HandoffCoordinator(settings: settings, bonjour: bonjourService, events: systemEvents)

        peerServer = PeerServer(port: settings.serverPort, serviceName: settings.thisMachineName) { [coordinator] request, isLocal in
            await coordinator!.handle(request, isLocal: isLocal)
        }
        peerServer.start()
        bonjourService.start()
        systemEvents.start()

        statusBarController = StatusBarController(settings: settings, bonjourService: bonjourService, coordinator: coordinator)
        hotkey = Hotkey { [coordinator] in
            Task { await coordinator?.toggle() }
        }
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await coordinator.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// First run: manage the paired Magic Trackpad by default.
    private func autoDetectDevices(_ settings: AppSettings) {
        let devices = BluetoothManager.shared.runSync { BluetoothManager.shared.pairedDevices() }
        guard let trackpad = devices.first(where: { $0.name.localizedCaseInsensitiveContains("trackpad") }) else { return }
        settings.deviceMACs = [trackpad.mac]
        settings.deviceNames[trackpad.mac] = trackpad.name
    }

    /// The menu shows device names; older versions could store only the address.
    private func fillMissingNames(_ settings: AppSettings) {
        let missing = settings.deviceMACs.filter { (settings.deviceNames[$0] ?? $0) == $0 }
        guard !missing.isEmpty else { return }
        let devices = BluetoothManager.shared.runSync { BluetoothManager.shared.pairedDevices() }
        for device in devices where missing.contains(device.mac) {
            settings.deviceNames[device.mac] = device.name
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
