import AppKit
import IOKit.pwr_mgt

/// Screen lock/unlock, system sleep/wake and power-off, delivered on the main
/// actor. Sleep is *held* until the handler calls its completion (macOS caps
/// the delay at ~30 s), which gives a closing lid time to hand the trackpad
/// to the other Mac while the network is still up.
@MainActor
final class SystemEvents {
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?
    var onWillSleep: ((_ done: @escaping () -> Void) -> Void)?
    var onDidWake: (() -> Void)?
    var onWillPowerOff: (() -> Void)?

    private(set) var isLocked = false
    private(set) var isAsleep = false

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isLocked else { return }
                self.isLocked = true
                self.onLock?()
            }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                self.isLocked = false
                self.onUnlock?()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWillPowerOff?() }
        }
        isLocked = Self.queryScreenLocked()
        registerForSleep()
    }

    private func registerForSleep() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, messageType, argument in
            guard let context else { return }
            let me = Unmanaged<SystemEvents>.fromOpaque(context).takeUnretainedValue()
            let notificationID = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                me.handlePower(messageType: messageType, notificationID: notificationID)
            }
        }, &notifier)
        if rootPort == 0 {
            Log.write("Sys", "IORegisterForSystemPower failed — sleep handoff disabled")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                           .commonModes)
    }

    // iokit_common_msg() values; the C macros don't import into Swift.
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280
    private static let systemHasPoweredOn: natural_t = 0xE000_0300

    private func handlePower(messageType: natural_t, notificationID: Int) {
        let id = notificationID
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, id)
        case Self.systemWillSleep:
            isAsleep = true
            var released = false
            let allow = { [weak self] in
                guard let self, !released else { return }
                released = true
                IOAllowPowerChange(self.rootPort, id)
            }
            // Never hold sleep past macOS's own limit, whatever the handler does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { allow() }
            if let onWillSleep { onWillSleep(allow) } else { allow() }
        case Self.systemHasPoweredOn:
            isAsleep = false
            onDidWake?()
        default:
            break
        }
    }

    /// Seconds since the last keyboard/mouse/trackpad input on this Mac.
    static func idleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private static func queryScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
