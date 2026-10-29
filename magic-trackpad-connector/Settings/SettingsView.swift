import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var bonjourService: BonjourService

    @State private var paired: [BluetoothManager.PairedDevice] = []
    @State private var portString: String = ""

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
            Section("Devices to move between Macs") {
                if rows.isEmpty {
                    Text("No paired Bluetooth devices found.").foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.mac) { row in
                    Toggle(isOn: binding(for: row.mac, name: row.name)) {
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(row.mac).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Magic Trackpad, Keyboard and Mouse work. Devices that pair with several hosts on their own (AirPods) don't need this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("This Mac") {
                Picker("Role", selection: $settings.role) {
                    Text("Main (orchestrator)").tag(MacRole.primary)
                    Text("Secondary").tag(MacRole.secondary)
                }
                Text("The main Mac takes the devices whenever no one else has them — e.g. after a failed transfer. Set exactly one Mac as Main.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Automatic handoff (lock, sleep, shutdown, startup)", isOn: $settings.autoHandoff)
                LabeledContent("Name") {
                    TextField("", text: $settings.thisMachineName).multilineTextAlignment(.trailing)
                }
                LabeledContent("Toggle hotkey") { Text("⌃⌥⌘T") }
            }

            Section("Network") {
                LabeledContent("Other Mac") {
                    if let name = bonjourService.peerName {
                        Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not found — run the app there too", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Fallback host") {
                    TextField("", text: $settings.peerHost, prompt: Text("other-mac.local"))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Port") {
                    TextField("", text: $portString, prompt: Text("7890"))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: portString) { _, value in
                            if let v = Int(value), v > 0 { settings.serverPort = v }
                        }
                }
                Text("Port changes apply after relaunch. Both Macs must use the same port.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .onAppear {
            portString = String(settings.serverPort)
            Task {
                paired = await BluetoothManager.shared.run { BluetoothManager.shared.pairedDevices() }
            }
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
