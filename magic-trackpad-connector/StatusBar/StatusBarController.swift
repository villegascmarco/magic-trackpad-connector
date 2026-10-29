import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let bonjourService: BonjourService
    private let coordinator: HandoffCoordinator

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    init(settings: AppSettings, bonjourService: BonjourService, coordinator: HandoffCoordinator) {
        self.settings = settings
        self.bonjourService = bonjourService
        self.coordinator = coordinator
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        coordinator.onChange = { [weak self] in self?.updateIcon() }
        bonjourService.onPeerChanged = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if coordinator.isBusy {
            symbol = "arrow.left.arrow.right"
        } else if coordinator.holdsHere {
            symbol = "rectangle.and.hand.point.up.left.fill"
        } else {
            symbol = "rectangle.and.hand.point.up.left"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Magic Trackpad Connector")
            ?? NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !coordinator.holdsHere && !coordinator.isBusy
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
        // Refresh in the background; the next open shows fresh peer state.
        Task {
            await coordinator.refresh()
            _ = await coordinator.peerState()
        }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let peerName = coordinator.lastPeer?.name ?? bonjourService.peerName ?? "Other Mac"
        let peerReachable = bonjourService.peerEndpoint != nil

        let location: String
        if !settings.isConfigured {
            location = "No device configured"
        } else if coordinator.isBusy {
            location = "Transferring…"
        } else if coordinator.holdsHere {
            location = "Connected to this Mac"
        } else if coordinator.lastPeer?.holds == true {
            location = "Connected to \(peerName)"
        } else {
            location = "Not connected"
        }
        addLabel(menu, deviceSummary() + ": " + location)

        menu.addItem(.separator())
        let toggleTitle = coordinator.holdsHere ? "Send to \(peerName)" : "Bring Here"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(handleToggle), keyEquivalent: "t")
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.target = self
        toggle.isEnabled = settings.isConfigured && !coordinator.isBusy && (peerReachable || !coordinator.holdsHere)
        menu.addItem(toggle)

        let auto = NSMenuItem(title: "Automatic Handoff", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = settings.autoHandoff ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        addLabel(menu, peerReachable ? "● \(peerName)" : "○ Other Mac: offline")
        addLabel(menu, "This Mac: \(settings.role == .primary ? "main (orchestrator)" : "secondary")")
        if !coordinator.lastResult.isEmpty { addLabel(menu, coordinator.lastResult) }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func deviceSummary() -> String {
        guard let first = settings.deviceMACs.first else { return "Trackpad" }
        let name = settings.displayName(first)
        return settings.deviceMACs.count > 1 ? "\(name) +\(settings.deviceMACs.count - 1)" : name
    }

    private func addLabel(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func handleToggle() {
        Task { await coordinator.toggle() }
    }

    @objc private func toggleAuto() {
        settings.autoHandoff.toggle()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, bonjourService: bonjourService))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Magic Trackpad Connector"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
