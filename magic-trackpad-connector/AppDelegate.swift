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
            await autoDetectTrackpadIfNeeded(settings: settings, bluetooth: bluetooth)
            await coordinator.connectOnLaunch()
            statusBarController.updateIcon()
        }
    }

    private func autoDetectTrackpadIfNeeded(settings: AppSettings, bluetooth: BluetoothManager) async {
        guard !settings.isTrackpadConfigured else { return }
        let task = Task.detached(priority: .userInitiated) { try bluetooth.findMagicTrackpad() }
        guard let trackpad = try? await task.value else { return }
        settings.trackpadMAC = trackpad.mac
        settings.trackpadName = trackpad.name
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
