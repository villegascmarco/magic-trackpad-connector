import AppKit
import ServiceManagement
import SwiftUI

/// A standard settings window: toolbar tabs, the window titled after the
/// selected pane, and the window resizing to fit each pane.
@MainActor
final class SettingsWindowController: NSWindowController {
    enum Pane: Int { case general, devices, network }

    private let tabs = NSTabViewController()

    init(settings: AppSettings, bonjourService: BonjourService, coordinator: HandoffCoordinator) {
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)

        add(GeneralPane(settings: settings), "General", "gearshape")
        add(DevicesPane(settings: settings, coordinator: coordinator), "Devices",
            "rectangle.and.hand.point.up.left")
        add(NetworkPane(settings: settings, bonjourService: bonjourService), "Network", "network")
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func add(_ view: some View, _ title: String, _ symbol: String) {
        let hosting = NSHostingController(rootView: view.frame(width: 500).fixedSize(horizontal: false, vertical: true))
        hosting.sizingOptions = .preferredContentSize
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    func show(_ pane: Pane) {
        tabs.selectedTabViewItemIndex = pane.rawValue
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil) // don't open with the Name field selected
        NSApp.activate()
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var settings: AppSettings
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.autoHandoff) {
                    Text("Automatic Handoff")
                    Text("Sends your devices to the other Mac when you lock, sleep or shut down this one, and takes them back when you return.")
                }
                LabeledContent("Send or Bring Devices") {
                    Text("⌃⌥⌘T").foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("Name", text: $settings.thisMachineName)
                Picker(selection: $settings.role) {
                    Text("Main").tag(MacRole.primary)
                    Text("Secondary").tag(MacRole.secondary)
                } label: {
                    Text("Role")
                    Text("The main Mac takes the devices whenever no one else has them, such as after a failed transfer. Choose Main on exactly one Mac.")
                }
            } header: {
                Text("This Mac")
            }

            Section {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Log.write("App", "login item: \(error.localizedDescription)")
                        }
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Devices

private struct DevicesPane: View {
    @Bindable var settings: AppSettings
    var coordinator: HandoffCoordinator

    @State private var paired: [BluetoothManager.PairedDevice] = []

    /// Managed devices plus anything paired here, so a device that currently
    /// lives on the other Mac still shows up (checked).
    private var rows: [(mac: String, name: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for mac in settings.deviceMACs where seen.insert(mac).inserted {
            result.append((mac, paired.first { $0.mac == mac }?.name ?? settings.displayName(mac)))
        }
        for device in paired where seen.insert(device.mac).inserted {
            result.append((device.mac, device.name))
        }
        return result
    }

    var body: some View {
        Form {
            Section {
                if rows.isEmpty {
                    Text("No paired Bluetooth devices.").foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.mac) { row in
                    Toggle(isOn: binding(for: row.mac, name: row.name)) {
                        HStack(spacing: 10) {
                            DeviceBadge(symbol: DeviceIcon.symbol(forDevice: row.name),
                                        active: coordinator.connectedHere.contains(row.mac))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name)
                                Text(coordinator.connectedHere.contains(row.mac) ? "Connected" : row.mac)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Devices to Move Between Macs")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Magic Trackpad, Keyboard and Mouse are supported. Devices that pair with several Macs on their own, like AirPods, don’t need this app.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Bluetooth Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .task {
            paired = await BluetoothManager.shared.run { BluetoothManager.shared.pairedDevices() }
        }
    }

    private func binding(for mac: String, name: String) -> Binding<Bool> {
        Binding(
            get: { settings.deviceMACs.contains(mac) },
            set: { on in
                if on {
                    if !settings.deviceMACs.contains(mac) { settings.deviceMACs.append(mac) }
                    settings.deviceNames[mac] = name
                } else {
                    settings.deviceMACs.removeAll { $0 == mac }
                }
            }
        )
    }
}

// MARK: - Network

private struct NetworkPane: View {
    @Bindable var settings: AppSettings
    var bonjourService: BonjourService

    private var port: Binding<Int> {
        Binding(get: { settings.serverPort }, set: { if (1...65535).contains($0) { settings.serverPort = $0 } })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Other Mac") {
                    if let name = bonjourService.peerName {
                        Label {
                            Text(name)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(.green).imageScale(.small)
                        }
                    } else {
                        Label {
                            Text("Not Found")
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(.secondary).imageScale(.small)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if bonjourService.peerName == nil {
                    Text("Open Magic Trackpad Connector on your other Mac. Both Macs must be on the same network.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("Fallback Address", text: $settings.peerHost, prompt: Text("other-mac.local"))
                TextField("Port", value: port, format: .number.grouping(.never))
            } header: {
                Text("Connection")
            } footer: {
                Text("The fallback address is used when the other Mac can’t be found automatically. Port changes take effect after relaunching, and both Macs must use the same port.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
