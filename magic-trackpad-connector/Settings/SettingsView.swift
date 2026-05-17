import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var bonjourService: BonjourService

    @State private var scannedDevices: [(mac: String, name: String)] = []
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var portString: String = ""

    var body: some View {
        Form {
            Section("Trackpad") {
                HStack {
                    TextField("AA:BB:CC:DD:EE:FF", text: $settings.trackpadMAC)
                        .font(.system(.body, design: .monospaced))
                    Button(isScanning ? "Scanning…" : "Scan") {
                        Task { await scanDevices() }
                    }
                    .disabled(isScanning)
                }

                if let error = scanError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if !scannedDevices.isEmpty {
                    Picker("Select device", selection: $settings.trackpadMAC) {
                        Text("— choose —").tag("")
                        ForEach(scannedDevices, id: \.mac) { device in
                            Text("\(device.name)  (\(device.mac))").tag(device.mac)
                        }
                    }
                }
            }

            Section("This Machine") {
                TextField("Name", text: $settings.thisMachineName)
                Text("This name is advertised to the other Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("7890", text: $portString)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: portString) { _, newValue in
                            if let v = Int(newValue), v > 0 {
                                settings.serverPort = v
                            }
                        }
                }

                HStack {
                    Text("Peer discovered")
                    Spacer()
                    if bonjourService.isPeerOnline, let name = bonjourService.peerName {
                        Label(name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("None", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 320)
        .padding()
        .onAppear {
            portString = String(settings.serverPort)
        }
    }

    private func scanDevices() async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        // Capture shared instance before entering detached task to avoid
        // crossing @MainActor boundary inside the Sendable closure.
        let bt = BluetoothManager.shared
        do {
            let devices = try await Task.detached(priority: .userInitiated) {
                try bt.pairedDevices()
            }.value
            scannedDevices = devices
            if devices.isEmpty {
                scanError = "No paired Bluetooth devices found."
            }
        } catch {
            scanError = error.localizedDescription
        }
    }
}
