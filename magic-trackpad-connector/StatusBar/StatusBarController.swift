import AppKit
import SwiftUI

/// Menu bar extra. Click opens the Control Center–style glass panel
/// (`ControlPanel`); right-click opens a classic menu laid out like the system
/// Bluetooth / Wi-Fi menus (section headers, one row per device, actions, app
/// commands).
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let bonjourService: BonjourService
    private let coordinator: HandoffCoordinator

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var panel: ControlPanelController!
    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, bonjourService: bonjourService, coordinator: coordinator)

    init(settings: AppSettings, bonjourService: BonjourService, coordinator: HandoffCoordinator) {
        self.settings = settings
        self.bonjourService = bonjourService
        self.coordinator = coordinator
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel = ControlPanelController(
            settings: settings, bonjourService: bonjourService, coordinator: coordinator,
            actions: .init(toggle: { [weak self] in self?.handleToggle() },
                           settings: { [weak self] pane in self?.settingsWindow.show(pane) },
                           about: { [weak self] in self?.openAbout() }))
        panel.onClose = { [weak self] in self?.statusItem.button?.highlight(false) }
        coordinator.onChange = { [weak self] in self?.updateIcon() }
        bonjourService.onPeerChanged = { [weak self] in self?.updateIcon() }
        coordinator.onShowUI = { [weak self] what in self?.show(what) }
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
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !coordinator.holdsHere && !coordinator.isBusy
        button.toolTip = "Magic Trackpad Connector — " + locationText
    }

    private var peerName: String {
        coordinator.lastPeer?.name ?? bonjourService.peerName ?? "Other Mac"
    }

    private var locationText: String {
        if !settings.isConfigured { return "No devices chosen" }
        if coordinator.isBusy { return "Moving…" }
        if coordinator.holdsHere { return "Connected to this Mac" }
        if coordinator.lastPeer?.holds == true { return "On \(peerName)" }
        return "Not connected"
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            panel.close()
            statusItem.menu = menu // attach only for this click, so left-click stays the panel
            button.performClick(nil)
            statusItem.menu = nil
        } else if panel.isOpen {
            panel.close()
        } else {
            button.highlight(true)
            panel.show(below: button)
        }
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
        menu.autoenablesItems = false
        let peerReachable = bonjourService.peerEndpoint != nil

        menu.addItem(.sectionHeader(title: "Devices"))
        if settings.deviceMACs.isEmpty {
            menu.addItem(item("Choose Devices…", symbol: "plus.circle", action: #selector(openDevices)))
        }
        for mac in settings.deviceMACs {
            let name = settings.displayName(mac)
            let here = coordinator.connectedHere.contains(mac)
            let row = item(name, action: #selector(openDevices))
            row.image = DeviceIcon.badge(DeviceIcon.symbol(forDevice: name), active: here)
            row.subtitle = deviceStatus(here: here)
            menu.addItem(row)
        }
        if coordinator.isRecovering {
            let hint = item("Switch the trackpad off and on", symbol: "exclamationmark.triangle")
            hint.subtitle = "It’s still bound to a Mac that went away."
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())
        let toggle = coordinator.holdsHere
            ? item("Send to \(peerName)", symbol: "arrow.up.forward.circle", action: #selector(handleToggle))
            : item("Bring Here", symbol: "arrow.down.backward.circle", action: #selector(handleToggle))
        toggle.keyEquivalent = "t"
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.isEnabled = settings.isConfigured && !coordinator.isBusy && (peerReachable || !coordinator.holdsHere)
        menu.addItem(toggle)

        let auto = item("Automatic Handoff", symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                        action: #selector(toggleAuto))
        auto.state = settings.autoHandoff ? .on : .off
        menu.addItem(auto)

        menu.addItem(.sectionHeader(title: "Other Mac"))
        let peer = item(peerReachable ? peerName : "Not Found", action: #selector(openNetwork))
        peer.image = DeviceIcon.badge(DeviceIcon.symbol(forMac: peerName), active: peerReachable)
        peer.subtitle = peerReachable ? peerStatus : "Open the app on your other Mac."
        menu.addItem(peer)
        if !coordinator.lastResult.isEmpty, !coordinator.isRecovering {
            let last = item(coordinator.lastResult)
            last.isEnabled = false
            menu.addItem(last)
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", symbol: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(item("About Magic Trackpad Connector", symbol: "info.circle", action: #selector(openAbout)))
        let quit = item("Quit Magic Trackpad Connector", symbol: "power",
                        action: #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func deviceStatus(here: Bool) -> String {
        if coordinator.isBusy { return "Moving…" }
        if here { return "Connected" }
        if coordinator.lastPeer?.holds == true { return "On \(peerName)" }
        return "Not Connected"
    }

    private var peerStatus: String {
        guard let peer = coordinator.lastPeer else { return "Online" }
        var parts = [peer.available ? "Available" : "Locked or Asleep"]
        if peer.role == MacRole.primary.rawValue { parts.append("Main Mac") }
        return parts.joined(separator: " · ")
    }

    private func item(_ title: String, symbol: String? = nil, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    // MARK: - Actions

    @objc private func handleToggle() {
        Task { await coordinator.toggle() }
    }

    @objc private func toggleAuto() {
        settings.autoHandoff.toggle()
    }

    private func show(_ what: String) {
        switch what {
        case "general": openSettings()
        case "devices": openDevices()
        case "network": openNetwork()
        case "about": openAbout()
        case "menu":
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        default: if let button = statusItem.button { button.highlight(true); panel.show(below: button) }
        }
    }

    @objc private func openSettings() { settingsWindow.show(.general) }
    @objc private func openDevices() { settingsWindow.show(.devices) }
    @objc private func openNetwork() { settingsWindow.show(.network) }

    @objc private func openAbout() {
        NSApp.activate()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Moves your Magic Trackpad, Keyboard and Mouse between two Macs.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: centered]),
        ])
    }
}
