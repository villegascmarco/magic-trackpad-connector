import Foundation
import IOBluetooth
import IOKit.hid

/// Every Bluetooth operation, in-process through IOBluetooth.
///
/// Why not blueutil: it has no way to inherit this app's Bluetooth permission
/// when started from launchd/SSH (it blocks forever waiting on a TCC prompt
/// that can't be shown), and it never had the `--connectable` flag the old
/// design relied on. Running IOBluetooth inside the app bundle uses the app's
/// own one-time Bluetooth permission and needs nothing installed.
///
/// All calls run on one dedicated thread with a live run loop (pairing reports
/// through delegate callbacks) and are serialized by `opQueue`, so a pairing
/// spin can never interleave with another operation.
nonisolated final class BluetoothManager: NSObject, @unchecked Sendable {
    static let shared = BluetoothManager()

    private var thread: Thread!
    private var runLoop: CFRunLoop!
    private let opQueue = DispatchQueue(label: "bt.ops", qos: .userInitiated)

    private override init() {
        super.init()
        let started = DispatchSemaphore(value: 0)
        thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            RunLoop.current.add(Port(), forMode: .default) // keep the loop alive
            started.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "bluetooth"
        thread.qualityOfService = .userInitiated
        thread.start()
        started.wait()
    }

    // MARK: - Threading

    /// Run `work` on the Bluetooth thread, after every earlier operation.
    func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            opQueue.async {
                continuation.resume(returning: self.onThread(work))
            }
        }
    }

    /// Blocking variant for callers already off the main thread.
    func runSync<T>(_ work: @escaping () -> T) -> T {
        opQueue.sync { onThread(work) }
    }

    private func onThread<T>(_ work: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            result = work()
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        return result!
    }

    // MARK: - Primitives (call only inside run/runSync)

    static func normalize(_ mac: String) -> String {
        mac.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    private func device(_ mac: String) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: Self.normalize(mac))
    }

    var isPoweredOn: Bool {
        IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    }

    func isConnected(_ mac: String) -> Bool {
        device(mac)?.isConnected() ?? false
    }

    func isPaired(_ mac: String) -> Bool {
        device(mac)?.isPaired() ?? false
    }

    struct PairedDevice: Sendable {
        let mac: String
        let name: String
        let connected: Bool
    }

    func pairedDevices() -> [PairedDevice] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { d in
            guard let addr = d.addressString else { return nil }
            return PairedDevice(mac: Self.normalize(addr), name: d.name ?? addr, connected: d.isConnected())
        }
    }

    /// Host-initiated baseband connection. Page timeout is in seconds (max ~40).
    @discardableResult
    func connect(_ mac: String, timeout: Double = 5) -> IOReturn {
        guard let d = device(mac) else { return kIOReturnNoDevice }
        if d.isConnected() { return kIOReturnSuccess }
        let slots = UInt16(min(max(timeout, 1), 40) * 1600) // 0.625 ms units
        let rc = d.openConnection(nil, withPageTimeout: slots, authenticationRequired: false)
        Log.write("BT", "connect \(mac) -> \(Self.describe(rc)) connected=\(d.isConnected())")
        return rc
    }

    @discardableResult
    func disconnect(_ mac: String) -> IOReturn {
        guard let d = device(mac) else { return kIOReturnNoDevice }
        hidReadySince[Self.normalize(mac)] = nil
        let rc = d.closeConnection()
        Log.write("BT", "disconnect \(mac) -> \(Self.describe(rc))")
        return rc
    }

    /// Remove the pairing record (what "Forget This Device" does). If the link
    /// is up, macOS also sends the HID Virtual Cable Unplug to the device.
    /// Uses the same private `remove` selector as blueutil.
    func unpair(_ mac: String) {
        guard let d = device(mac) else { return }
        let wasConnected = d.isConnected()
        hidReadySince[Self.normalize(mac)] = nil
        let selector = NSSelectorFromString("remove")
        if d.responds(to: selector) {
            d.perform(selector)
        }
        waitFor(timeout: 3) { !d.isPaired() }
        Log.write("BT", "unpair \(mac) (link was up: \(wasConnected)) -> paired=\(d.isPaired())")
    }

    /// Host-initiated pairing (Just Works SSP for Magic devices: no PIN, no
    /// prompt). Spins this thread's run loop until the delegate reports.
    @discardableResult
    func pair(_ mac: String, timeout: TimeInterval = 20) -> IOReturn {
        guard let d = device(mac) else { return kIOReturnNoDevice }
        guard let pairing = IOBluetoothDevicePair(device: d) else { return kIOReturnError }
        hidReadySince[Self.normalize(mac)] = nil // a new link starts its own clock
        let delegate = PairDelegate()
        pairing.delegate = delegate
        var rc = pairing.start()
        if rc == kIOReturnSuccess {
            let deadline = Date().addingTimeInterval(timeout)
            while delegate.result == nil, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            if delegate.result == nil { pairing.stop() }
            rc = delegate.result ?? kIOReturnTimeout
        }
        Log.write("BT", "pair \(mac) -> \(Self.describe(rc)) paired=\(d.isPaired()) connected=\(d.isConnected())")
        return rc
    }

    /// Bluetooth HID devices macOS has opened (their IOHIDDevice exists).
    func hidDevices() -> [[String: String]] {
        var result: [[String: String]] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var info: [String: String] = [:]
            for key in ["Transport", "Product", "SerialNumber", "DeviceAddress", "PhysicalDeviceUniqueID"] {
                if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                    info[key] = "\(value)"
                }
            }
            if info["Transport"]?.localizedCaseInsensitiveContains("bluetooth") == true { result.append(info) }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    /// True once macOS has opened the device's HID channels — only then can
    /// it deliver the Virtual Cable Unplug. Unpairing before that removes our
    /// record without the device noticing, stranding it bound to a key nobody
    /// has (every host then gets 0x02 until it is power-cycled) — measured.
    func isHIDReady(_ mac: String) -> Bool {
        let address = Self.normalize(mac)
        let ready = isConnected(mac) && hidDevices().contains { info in
            info.values.contains { Self.normalize($0).contains(address) }
        }
        if !ready { hidReadySince[address] = nil }
        else if hidReadySince[address] == nil { hidReadySince[address] = Date() }
        return ready
    }

    /// When the HID channel was first seen open (Bluetooth thread only). The
    /// IOHIDDevice appears slightly before the device can process an unplug.
    private var hidReadySince: [String: Date] = [:]
    private let hidGrace: TimeInterval = 1.5

    /// Wait until the link is up AND the HID channels are open, then a short
    /// grace period. False if the link dropped or HID never came up.
    @discardableResult
    func settle(_ mac: String, timeout: TimeInterval = 12) -> Bool {
        let ready = waitFor(timeout: timeout) { !isConnected(mac) || isHIDReady(mac) }
        guard ready, isConnected(mac), let since = hidReadySince[Self.normalize(mac)] else {
            Log.write("BT", "settle \(mac): " + (isConnected(mac) ? "HID not ready after \(Int(timeout))s" : "link dropped"))
            return false
        }
        let deadline = since.addingTimeInterval(hidGrace) // no wait if long settled
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        return isConnected(mac)
    }

    /// Poll (while keeping the run loop serviced) until `condition` holds.
    @discardableResult
    func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        return true
    }

    static func describe(_ rc: IOReturn) -> String {
        rc == kIOReturnSuccess ? "ok" : String(format: "0x%08x", UInt32(bitPattern: rc))
    }

    private final class PairDelegate: NSObject, IOBluetoothDevicePairDelegate {
        var result: IOReturn?

        func devicePairingFinished(_ sender: Any!, error: IOReturn) {
            result = error
        }

        func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
            (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
        }

        func devicePairingPINCodeRequest(_ sender: Any!) {
            var pin = BluetoothPINCode()
            withUnsafeMutableBytes(of: &pin) { raw in
                for (i, c) in "0000".utf8.enumerated() { raw[i] = c }
            }
            (sender as? IOBluetoothDevicePair)?.replyPINCode(4, pinCode: &pin)
        }
    }
}
