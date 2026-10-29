import AppKit
import SwiftUI

/// The menu bar panel, built like Control Center: free-floating Liquid Glass
/// modules (capsules, circles, a square tile) under the status item, with no
/// sheet behind them.
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
        panel.contentView = hosting
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

/// Control Center's grid: 292 pt wide, 140 pt modules, 62 pt rows, 12 pt gaps.
private enum Grid {
    static let width: CGFloat = 292
    static let gap: CGFloat = 12
    static let row: CGFloat = 62
    static let half: CGFloat = (width - gap) / 2
    /// Two round buttons fill one half module exactly.
    static let circle: CGFloat = (half - gap) / 2
    /// Secondary text: Control Center's subtitles are a bright grey, not dim.
    static let subtitle = Color.primary.opacity(0.7)
}

/// Clear Liquid Glass plus the bright rim Control Center modules have:
/// strongest along the top-left and bottom-right curves.
private struct ModuleGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = true

    func body(content: Content) -> some View {
        content
            // The rim is part of the glass's content so it composites on top.
            .overlay {
                shape.strokeBorder(
                    LinearGradient(stops: [.init(color: .white.opacity(0.85), location: 0),
                                           .init(color: .white.opacity(0.12), location: 0.4),
                                           .init(color: .white.opacity(0.12), location: 0.6),
                                           .init(color: .white.opacity(0.6), location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
                    .allowsHitTesting(false)
            }
            // A faint white tint: Control Center's glass brightens what's behind it.
            .glassEffect(.clear.tint(.white.opacity(0.1)).interactive(interactive), in: shape)
    }
}

private extension View {
    func moduleGlass(_ shape: some InsettableShape, interactive: Bool = true) -> some View {
        modifier(ModuleGlass(shape: shape, interactive: interactive))
    }
}

struct ControlPanelView: View {
    @Bindable var settings: AppSettings
    var bonjourService: BonjourService
    var coordinator: HandoffCoordinator
    var actions: ControlPanelController.Actions

    private var peerReachable: Bool { bonjourService.peerEndpoint != nil }
    private var peerName: String { coordinator.lastPeer?.name ?? bonjourService.peerName ?? "Other Mac" }
    private var canMove: Bool {
        settings.isConfigured && !coordinator.isBusy && (peerReachable || !coordinator.holdsHere)
    }

    var body: some View {
        // Spacing 0: Control Center's modules sit apart and never morph together.
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: Grid.gap) {
                // Left column of capsules beside the square move tile, like
                // Wi-Fi / Bluetooth beside Now Playing.
                HStack(alignment: .top, spacing: Grid.gap) {
                    VStack(spacing: Grid.gap) {
                        if let first = settings.deviceMACs.first {
                            deviceModule(first)
                        } else {
                            Module(symbol: "plus", title: "Devices", subtitle: "Choose…") { actions.settings(.devices) }
                        }
                        Module(symbol: DeviceIcon.symbol(forMac: peerName), title: "Other Mac",
                               subtitle: peerReachable ? "\(peerName)\n\(peerStatus)" : "Not Found",
                               isOn: peerReachable) { actions.settings(.network) }
                    }
                    moveModule
                }

                HStack(spacing: Grid.gap) {
                    Module(symbol: "arrow.trianglehead.2.clockwise.rotate.90", title: "Automatic",
                           subtitle: settings.autoHandoff ? "On" : "Off", isOn: settings.autoHandoff) {
                        settings.autoHandoff.toggle()
                    }
                    CircleModule(symbol: "info", help: "About Magic Trackpad Connector", action: actions.about)
                    CircleModule(symbol: "power", help: "Quit Magic Trackpad Connector") { NSApp.terminate(nil) }
                }

                let more = Array(settings.deviceMACs.dropFirst())
                ForEach(Array(stride(from: 0, to: more.count, by: 2)), id: \.self) { i in
                    HStack(spacing: Grid.gap) {
                        deviceModule(more[i])
                        if i + 1 < more.count { deviceModule(more[i + 1]) } else { Spacer(minLength: 0) }
                    }
                }

                if coordinator.isRecovering {
                    WideModule(title: "Switch the Trackpad Off and On",
                               text: "It’s still bound to a Mac that went away.", symbol: "exclamationmark.triangle.fill")
                } else if !coordinator.lastResult.isEmpty {
                    WideModule(title: "Last Transfer", text: coordinator.lastResult, symbol: "clock")
                }

                Button { actions.settings(.general) } label: {
                    Text("Settings…").font(.system(size: 12)).foregroundStyle(Grid.subtitle)
                }
                .buttonStyle(.glass)
                .padding(.top, 6) // Control Center sets "Edit Controls" apart from the grid
            }
        }
        .frame(width: Grid.width)
        .padding(8)
    }

    private func deviceModule(_ mac: String) -> some View {
        let name = settings.displayName(mac)
        let here = coordinator.connectedHere.contains(mac)
        let status: String
        if coordinator.isBusy { status = "Moving…" }
        else if here { status = "Connected" }
        else if coordinator.lastPeer?.holds == true { status = "On \(peerName)" }
        else { status = "Not Connected" }
        return Module(symbol: DeviceIcon.symbol(forDevice: name), title: shortName(name), subtitle: status,
                      isOn: here) { actions.settings(.devices) }
    }

    /// "Villegas’s Magic Trackpad" → "Trackpad": a module title is one short
    /// word, like Control Center's "Wi-Fi" or "Bluetooth".
    private func shortName(_ name: String) -> String {
        var name = name
        for sep in ["’s ", "'s "] {
            if let r = name.range(of: sep) { name = String(name[r.upperBound...]) }
        }
        if name.hasPrefix("Magic ") { name.removeFirst("Magic ".count) }
        return name
    }

    /// The square module (Now Playing's slot): the one-click transfer.
    private var moveModule: some View {
        let sending = coordinator.holdsHere
        return Button(action: { if canMove { actions.toggle() } }) {
            VStack(alignment: .leading, spacing: 0) {
                IconCircle(symbol: sending ? "arrow.up.forward" : "arrow.down.backward",
                           isOn: canMove, busy: coordinator.isBusy, size: 40)
                Spacer(minLength: 0)
                Text(coordinator.isBusy ? "Moving…" : sending ? "Send to" : "Bring Here")
                    .font(.system(size: 13, weight: .semibold))
                Text(sending ? peerName : "from \(peerName)")
                    .font(.system(size: 11))
                    .foregroundStyle(Grid.subtitle)
                    .lineLimit(1)
                Text("⌃⌥⌘T")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(14)
            .frame(width: Grid.half, height: Grid.row * 2 + Grid.gap, alignment: .leading)
            .contentShape(.rect(cornerRadius: 30))
        }
        .buttonStyle(.plain)
        .moduleGlass(.rect(cornerRadius: 30), interactive: canMove)
        .opacity(canMove || coordinator.isBusy ? 1 : 0.6)
        .help("Send or bring the devices (⌃⌥⌘T)")
    }

    private var peerStatus: String {
        guard let peer = coordinator.lastPeer else { return "Online" }
        if !peer.available { return "Locked or Asleep" }
        return peer.role == MacRole.primary.rawValue ? "Main · Available" : "Available"
    }
}

/// The round icon inside a module: white with an accent glyph when on,
/// glass-dim with a primary glyph when off (Control Center's Wi-Fi look).
private struct IconCircle: View {
    let symbol: String
    var isOn = false
    var busy = false
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)))
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A 140 × 62 capsule: icon circle, title, subtitle.
private struct Module: View {
    let symbol: String
    let title: String
    let subtitle: String
    var isOn = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                IconCircle(symbol: symbol, isOn: isOn)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Grid.subtitle).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 13)
            .padding(.trailing, 6)
            .frame(width: Grid.half, height: Grid.row)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .moduleGlass(.capsule)
    }
}

/// A 62 pt glass circle with a single glyph (the small square controls).
private struct CircleModule: View {
    let symbol: String
    let help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: Grid.circle, height: Grid.circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .moduleGlass(.circle)
        .help(help)
    }
}

/// A full-width module (Display / Sound's slot) for status text.
private struct WideModule: View {
    let title: String
    let text: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(Grid.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: Grid.width, alignment: .leading)
        .frame(minHeight: Grid.row)
        .moduleGlass(.rect(cornerRadius: 22), interactive: false)
    }
}
