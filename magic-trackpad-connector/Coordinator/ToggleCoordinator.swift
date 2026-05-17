import AppKit
import Network

@MainActor
final class ToggleCoordinator {
    private let settings: AppSettings
    private let bluetooth: BluetoothManager
    private let bonjourService: BonjourService
    private let btQueue = DispatchQueue(label: "toggle.bt", qos: .userInitiated)

    var onStatusChanged: (() -> Void)?
    private(set) var isTrackpadConnected: Bool = false

    private var pollingTimer: Timer?

    init(settings: AppSettings, bluetooth: BluetoothManager, bonjourService: BonjourService) {
        self.settings = settings
        self.bluetooth = bluetooth
        self.bonjourService = bonjourService
    }

    func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshConnectionStatus()
            }
        }
    }

    func connectOnLaunch() async {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else { return }
        let bt = bluetooth
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            btQueue.async {
                try? bt.connect(mac: mac)
                continuation.resume()
            }
        }
        await refreshConnectionStatus()
    }

    func toggle() async {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else {
            showError("Trackpad MAC address is not configured.\nOpen Settings to configure it.")
            return
        }

        guard let peerEndpoint = bonjourService.peerEndpoint else {
            showError("Peer machine is not reachable.\nMake sure both Macs are on the same network and the app is running on the other Mac.")
            return
        }

        let connected = await checkIsConnected(mac: mac)

        if connected {
            await sendTrackpadToPeer(mac: mac, peerEndpoint: peerEndpoint)
        } else {
            await bringTrackpadHere(mac: mac, peerEndpoint: peerEndpoint)
        }

        await refreshConnectionStatus()
    }

    private func sendTrackpadToPeer(mac: String, peerEndpoint: NWEndpoint) async {
        do {
            _ = try await sendCommandToPeer(action: "connect", endpoint: peerEndpoint)
        } catch {
            showError("Could not connect trackpad on the other Mac:\n\(error.localizedDescription)\n\nNo changes were made.")
            return
        }
        let bt = bluetooth
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            btQueue.async {
                try? bt.disconnect(mac: mac)
                continuation.resume()
            }
        }
    }

    private func bringTrackpadHere(mac: String, peerEndpoint: NWEndpoint) async {
        do {
            _ = try await sendCommandToPeer(action: "disconnect", endpoint: peerEndpoint)
        } catch {
            showError("Could not disconnect trackpad on the other Mac:\n\(error.localizedDescription)\n\nNo changes were made.")
            return
        }
        let bt = bluetooth
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            btQueue.async {
                try? bt.connect(mac: mac)
                continuation.resume()
            }
        }
    }

    private func checkIsConnected(mac: String) async -> Bool {
        let bt = bluetooth
        return await withCheckedContinuation { continuation in
            btQueue.async {
                continuation.resume(returning: bt.isConnected(mac: mac))
            }
        }
    }

    func refreshConnectionStatus() async {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else {
            isTrackpadConnected = false
            onStatusChanged?()
            return
        }
        let connected = await checkIsConnected(mac: mac)
        isTrackpadConnected = connected
        onStatusChanged?()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Magic Trackpad Connector"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
