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

        // Already here — nothing to do.
        if await checkIsConnected(mac: mac) {
            await refreshConnectionStatus()
            return
        }

        // Wait briefly for Bonjour to discover the peer before deciding whether
        // to ask them to release first.
        try? await Task.sleep(for: .seconds(2))

        // If peer is online, politely ask it to disconnect before we try to grab
        // the trackpad. Ignore failures — we attempt the connect regardless.
        if let endpoint = bonjourService.peerEndpoint {
            _ = try? await sendCommandToPeer(action: "disconnect", endpoint: endpoint)
            try? await Task.sleep(for: .milliseconds(800))
        }

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
            showError("Trackpad not detected yet.\nOpen Settings — the app will scan automatically.")
            return
        }

        let connected = await checkIsConnected(mac: mac)
        let peerEndpoint = bonjourService.peerEndpoint

        if connected {
            // Trackpad is here — send to peer (requires peer online)
            guard let endpoint = peerEndpoint else {
                showError("Cannot send trackpad: the other Mac is not reachable.\nMake sure the app is running there too.")
                return
            }
            await sendTrackpadToPeer(mac: mac, peerEndpoint: endpoint)
        } else if let endpoint = peerEndpoint {
            // Trackpad is not here and peer is online — take it from peer
            await bringTrackpadHere(mac: mac, peerEndpoint: endpoint)
        } else {
            // Trackpad is not connected anywhere — just connect locally
            await connectLocally(mac: mac)
        }

        await refreshConnectionStatus()
    }

    func connectLocally() async {
        let mac = settings.trackpadMAC
        guard !mac.isEmpty else { return }
        await connectLocally(mac: mac)
        await refreshConnectionStatus()
    }

    private func connectLocally(mac: String) async {
        let bt = bluetooth
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            btQueue.async {
                try? bt.connect(mac: mac)
                continuation.resume()
            }
        }
    }

    private func sendTrackpadToPeer(mac: String, peerEndpoint: NWEndpoint) async {
        // Pre-flight: verify peer is reachable AND ready to receive before
        // touching the local connection. Nothing is changed if this fails.
        do {
            _ = try await sendCommandToPeer(action: "ready", endpoint: peerEndpoint)
        } catch {
            showError("The other Mac is not ready to receive the trackpad:\n\(error.localizedDescription)\n\nNo changes were made.")
            return
        }

        // Disconnect locally — Bluetooth only allows one host at a time.
        let bt = bluetooth
        let disconnected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            btQueue.async {
                do {
                    try bt.disconnect(mac: mac)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
        guard disconnected else {
            showError("Could not disconnect trackpad from this Mac.\n\nNo changes were made.")
            return
        }

        // Give the Bluetooth stack time to fully release the device before
        // the peer attempts to claim it.
        try? await Task.sleep(for: .milliseconds(800))

        do {
            _ = try await sendCommandToPeer(action: "connect", endpoint: peerEndpoint)
        } catch {
            // Rollback: reconnect locally so the trackpad isn't stranded.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                btQueue.async { try? bt.connect(mac: mac); continuation.resume() }
            }
            showError("The other Mac failed to connect the trackpad.\nReconnected here as fallback.\n\n\(error.localizedDescription)")
        }
    }

    private func bringTrackpadHere(mac: String, peerEndpoint: NWEndpoint) async {
        // Tell the peer to release the trackpad.
        do {
            _ = try await sendCommandToPeer(action: "disconnect", endpoint: peerEndpoint)
        } catch {
            showError("Could not disconnect trackpad on the other Mac:\n\(error.localizedDescription)\n\nNo changes were made.")
            return
        }

        // Give the Bluetooth stack time to fully release the device.
        try? await Task.sleep(for: .milliseconds(800))

        let bt = bluetooth
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            btQueue.async {
                do {
                    try bt.connect(mac: mac)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
        if !success {
            showError("The trackpad was released by the other Mac but this Mac could not connect.\nTry again in a moment.")
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
