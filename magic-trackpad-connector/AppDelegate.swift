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

        // Run at login (user can turn it off in System Settings → Login Items).
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        if !settings.isConfigured { autoDetectDevices(settings) }

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
