import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var peerServer: PeerServer!
    private var bonjourService: BonjourService!
    private var coordinator: ToggleCoordinator!
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settings = AppSettings.shared
        let bluetooth = BluetoothManager.shared

        peerServer = PeerServer(settings: settings, bluetooth: bluetooth)
        peerServer.start()

        bonjourService = BonjourService(settings: settings)
        bonjourService.start()

        coordinator = ToggleCoordinator(
            settings: settings,
            bluetooth: bluetooth,
            bonjourService: bonjourService
        )

        statusBarController = StatusBarController(
            settings: settings,
            bonjourService: bonjourService,
            coordinator: coordinator
        )

        Task {
            await coordinator.connectOnLaunch()
            statusBarController.updateIcon()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
