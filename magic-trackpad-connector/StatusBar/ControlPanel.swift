import AppKit
import SwiftUI

/// The menu bar panel, built like Control Center: a Liquid Glass sheet under
/// the status item holding glass tiles with round toggle icons.
@MainActor
final class ControlPanelController: NSObject, NSWindowDelegate {
    struct Actions {
        var toggle: () -> Void
        var settings: (SettingsWindowController.Pane) -> Void
        var about: () -> Void
    }

    private let panel: NSPanel
    private var hosting: NSView!
    private var outsideClickMonitor: Any?
    private var refreshTimer: Timer?
    private let coordinator: HandoffCoordinator
    var onClose: (() -> Void)?

    var isOpen: Bool { panel.isVisible }

    init(settings: AppSettings, bonjourService: BonjourService, coordinator: HandoffCoordinator, actions: Actions) {
        self.coordinator = coordinator
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        var actions = actions
        let settingsAction = actions.settings
        let aboutAction = actions.about
        actions.settings = { [weak self] pane in self?.close(); settingsAction(pane) }
        actions.about = { [weak self] in self?.close(); aboutAction() }

        hosting = NSHostingView(rootView: ControlPanelView(
            settings: settings, bonjourService: bonjourService, coordinator: coordinator, actions: actions))
        let glass = NSGlassEffectView()
        glass.cornerRadius = 20
        glass.contentView = hosting
        panel.contentView = glass
    }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        refresh()
        let size = hosting.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height),
                       display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in MainActor.assumeIsolated { self?.close() }
        }
        // Peer state is fetched on demand; keep it fresh while the panel is up.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        panel.orderOut(nil)
        onClose?()
    }

    private func refresh() {
        Task {
            await coordinator.refresh()
            _ = await coordinator.peerState()
            fitToContent()
        }
    }

    /// Tiles come and go (recovery hint, last result): resize with the top
    /// edge pinned under the menu bar.
    private func fitToContent() {
        let size = hosting.fittingSize
        guard panel.isVisible, size != panel.frame.size else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func cancelOperation(_ sender: Any?) { close() }
}

/// Borderless panels can't become key by default; we need key for Esc and
/// resign-key dismissal, without activating the app (nonactivatingPanel).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        (delegate as? ControlPanelController)?.cancelOperation(sender)
    }
}

// MARK: - Content

struct ControlPanelView: View {
    @Bindable var settings: AppSettings
    var bonjourService: BonjourService
    var coordinator: HandoffCoordinator
    var actions: ControlPanelController.Actions

    private var peerReachable: Bool { bonjourService.peerEndpoint != nil }
    private var peerName: String { coordinator.lastPeer?.name ?? bonjourService.peerName ?? "Other Mac" }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if settings.deviceMACs.isEmpty {
                    Tile(symbol: "plus", title: "Choose Devices", subtitle: "None selected") {
                        actions.settings(.devices)
                    }
                }
                ForEach(settings.deviceMACs, id: \.self) { mac in
                    deviceTile(mac)
                }
                if coordinator.isRecovering {
                    Tile(symbol: "exclamationmark.triangle.fill", title: "Switch the Trackpad Off and On",
                         subtitle: "It’s still bound to a Mac that went away.", subtitleLines: 2, tint: .orange)
                }

                HStack(spacing: 8) {
                    moveTile
                    Tile(symbol: "arrow.trianglehead.2.clockwise.rotate.90", title: "Automatic",
                         subtitle: settings.autoHandoff ? "On" : "Off", isOn: settings.autoHandoff) {
                        settings.autoHandoff.toggle()
                    }
                }

                Tile(symbol: DeviceIcon.symbol(forMac: peerName),
                     title: peerReachable ? peerName : "Other Mac",
                     subtitle: peerReachable ? peerStatus : "Not found — open the app there",
                     isOn: peerReachable) {
                    actions.settings(.network)
                }

                if !coordinator.lastResult.isEmpty, !coordinator.isRecovering {
                    Text(coordinator.lastResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }

                HStack(spacing: 6) {
                    Button("Settings…") { actions.settings(.general) }
                        .buttonStyle(.glass)
                    Spacer()
                    Button(action: actions.about) { Image(systemName: "info") }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("About Magic Trackpad Connector")
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("Quit Magic Trackpad Connector")
                }
            }
        }
        .padding(10)
        .frame(width: 290)
    }

    private func deviceTile(_ mac: String) -> some View {
        let name = settings.displayName(mac)
        let here = coordinator.connectedHere.contains(mac)
        let status: String
        if coordinator.isBusy { status = "Moving…" }
        else if here { status = "Connected" }
        else if coordinator.lastPeer?.holds == true { status = "On \(peerName)" }
        else { status = "Not Connected" }
        return Tile(symbol: DeviceIcon.symbol(forDevice: name), title: name, subtitle: status, isOn: here) {
            actions.settings(.devices)
        }
    }

    private var moveTile: some View {
        let enabled = settings.isConfigured && !coordinator.isBusy && (peerReachable || !coordinator.holdsHere)
        return Tile(symbol: coordinator.holdsHere ? "arrow.up.forward" : "arrow.down.backward",
                    title: coordinator.holdsHere ? "Send" : "Bring Here",
                    subtitle: coordinator.holdsHere ? peerName : "⌃⌥⌘T",
                    busy: coordinator.isBusy, action: enabled ? actions.toggle : nil)
            .help("Send or bring the devices (⌃⌥⌘T)")
            .opacity(enabled || coordinator.isBusy ? 1 : 0.5)
    }

    private var peerStatus: String {
        guard let peer = coordinator.lastPeer else { return "Online" }
        var parts = [peer.available ? "Available" : "Locked or Asleep"]
        if peer.role == MacRole.primary.rawValue { parts.append("Main") }
        return parts.joined(separator: " · ")
    }
}

/// A Control Center module: glass rounded rectangle, round icon on the
/// left (white when on), title and subtitle.
private struct Tile: View {
    let symbol: String
    let title: String
    let subtitle: String
    var isOn = false
    var subtitleLines = 1
    var tint: Color = .accentColor
    var busy = false
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.14)))
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(subtitleLines)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .disabled(action == nil && !busy)
        .glassEffect(.regular.interactive(action != nil), in: .rect(cornerRadius: 15))
    }
}
