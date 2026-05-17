import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let bonjourService: BonjourService
    private let coordinator: ToggleCoordinator

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    init(settings: AppSettings, bonjourService: BonjourService, coordinator: ToggleCoordinator) {
        self.settings = settings
        self.bonjourService = bonjourService
        self.coordinator = coordinator
        super.init()
        setupStatusItem()
        coordinator.onStatusChanged = { [weak self] in self?.updateIcon() }
        bonjourService.onPeerChanged = { [weak self] in self?.updateIcon() }
        coordinator.startPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let connected = coordinator.isTrackpadConnected
        // Try preferred symbol first, fall back to simpler guaranteed ones, then plain text.
        let candidates = connected
            ? ["dot.radiowaves.left.and.right", "wifi", "antenna.radiowaves.left.and.right"]
            : ["dot.radiowaves.left.and.right.slash", "wifi.slash", "wifi.exclamationmark"]
        if let symbolName = candidates.first(where: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }),
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = connected ? "⌨︎" : "⌨︎?"
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let connected = coordinator.isTrackpadConnected
        let peerOnline = bonjourService.isPeerOnline
        let peerName = bonjourService.peerName ?? "Other Mac"

        let statusLabel = NSMenuItem(
            title: "Trackpad: \(connected ? "Connected" : "Disconnected")",
            action: nil,
            keyEquivalent: ""
        )
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)

        menu.addItem(.separator())

        let toggleTitle = connected
            ? "Send to \(peerName)"
            : "Take from \(peerName)"
        let toggleItem = NSMenuItem(
            title: toggleTitle,
            action: #selector(handleToggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.isEnabled = peerOnline && !settings.trackpadMAC.isEmpty
        menu.addItem(toggleItem)

        if !bluetooth.isAvailable {
            let warnItem = NSMenuItem(
                title: "⚠ blueutil not found (brew install blueutil)",
                action: nil,
                keyEquivalent: ""
            )
            warnItem.isEnabled = false
            menu.addItem(warnItem)
        }

        menu.addItem(.separator())

        let peerStatus = peerOnline ? "● \(peerName)" : "○ Peer: Offline"
        let peerItem = NSMenuItem(title: peerStatus, action: nil, keyEquivalent: "")
        peerItem.isEnabled = false
        menu.addItem(peerItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private var bluetooth: BluetoothManager { .shared }

    @objc private func handleToggle() {
        Task { @MainActor in
            await coordinator.toggle()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, bonjourService: bonjourService))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Magic Trackpad Connector"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 320))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
