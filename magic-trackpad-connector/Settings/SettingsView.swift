import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var bonjourService: BonjourService

    @State private var availableTrackpads: [(mac: String, name: String)] = []
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var portString: String = ""

    var body: some View {
        Form {
            Section("Trackpad") {
                if settings.isTrackpadConfigured {
                    LabeledContent("Detected") {
                        Label(settings.trackpadName.isEmpty ? settings.trackpadMAC : settings.trackpadName,
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if availableTrackpads.count > 1 {
                        Picker("Switch to", selection: $settings.trackpadMAC) {
                            ForEach(availableTrackpads, id: \.mac) { device in
                                Text(device.name).tag(device.mac)
                            }
                        }
                        .onChange(of: settings.trackpadMAC) { _, mac in
                            settings.trackpadName = availableTrackpads.first { $0.mac == mac }?.name ?? ""
                        }
                    }
                } else {
                    LabeledContent("Trackpad") {
                        Label("Not found", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }

                if let error = scanError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }

                Button(isScanning ? "Connecting…" : "Re-detect & Connect") {
                    Task { await scanAndConnect() }
                }
                .disabled(isScanning)
            }

            Section("This Machine") {
                LabeledContent("Name") {
                    TextField("", text: $settings.thisMachineName,
                              prompt: Text("My Mac").foregroundColor(.secondary))
                        .multilineTextAlignment(.trailing)
                }
                Text("This name identifies this Mac to the other Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                LabeledContent("Port") {
                    TextField("", text: $portString,
                              prompt: Text("7890").foregroundColor(.secondary))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: portString) { _, newValue in
                            if let v = Int(newValue), v > 0 { settings.serverPort = v }
                        }
                }
                LabeledContent("Peer") {
                    if bonjourService.isPeerOnline, let name = bonjourService.peerName {
                        Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not found — launch app on the other Mac", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .padding()
        .onAppear {
            portString = String(settings.serverPort)
            Task { await scanTrackpads() }
        }
    }

    private func scanAndConnect() async {
        await scanTrackpads()
        // After scanning/detecting, attempt to connect to this Mac
        let bt = BluetoothManager.shared
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else { return }
        await Task.detached(priority: .userInitiated) { try? bt.connect(mac: mac) }.value
    }

    private func scanTrackpads() async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        let bt = BluetoothManager.shared
        do {
            let all = try await Task.detached(priority: .userInitiated) {
                try bt.pairedDevices()
            }.value
            availableTrackpads = all.filter { $0.name.localizedCaseInsensitiveContains("trackpad") }
            if availableTrackpads.isEmpty {
                scanError = "No Magic Trackpad found in paired devices."
            } else if !settings.isTrackpadConfigured, let first = availableTrackpads.first {
                settings.trackpadMAC = first.mac
                settings.trackpadName = first.name
            }
        } catch {
            scanError = error.localizedDescription
        }
    }
}
