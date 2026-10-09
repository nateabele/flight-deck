// The macOS host's Darwin-only half: the IOKit idle- and display-sleep assertions a run holds
// (§6.1, §6.3), and the console-user and screen-lock checks (`CGSessionCopyCurrentDictionary`)
// the screen preflight reads. hostd injects both into `Runner`.
//
// Everything in this target sits inside `#if os(macOS)`. On Linux the target is still built
// (the manifest cannot drop a target per platform without a conditional manifest), so it must
// compile to an empty module there; an unguarded `import IOKit` would break the Linux hostd
// build that `scripts/test-hostkit.sh` runs.
#if os(macOS)
import CoreGraphics
import Foundation
import HostKit
import IOKit.ps
import IOKit.pwr_mgt

public struct IOKitPowerAssertions: PowerAsserting {
    public init() {}

    public func hold(_ kind: PowerAssertionKind, reason: String) -> PowerAssertion {
        let type: String
        switch kind {
        // "User idle": the machine stays up while the run works, but a lid close or an
        // explicit Sleep still wins, which is the user's call to make, not hostd's.
        case .idleSleep: type = kIOPMAssertionTypePreventUserIdleSystemSleep
        case .displaySleep: type = kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &id)
        guard result == kIOReturnSuccess else { return .none() }
        let held = id
        return PowerAssertion { _ = IOPMAssertionRelease(held) }
    }
}

/// IOKit's providing power source, watched through `IOPSNotificationCreateRunLoopSource` on the
/// main run loop (hostd runs AppKit's, for the screen panel), for "keep this Mac awake while
/// plugged in" (`KeepAwakeHolder`).
public final class IOKitPowerSource: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable (PowerSource) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    public var current: PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return Self.source(providingType: type)
    }

    /// A desktop Mac reports AC too. A UPS supplying power means the mains are out, which is
    /// battery for this purpose: the point is not to drain a battery keeping a screen lit.
    public static func source(providingType type: String?) -> PowerSource {
        switch type {
        case kIOPMACPowerKey: .ac
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: .battery
        default: .unknown
        }
    }

    public func start(onChange: @escaping @Sendable (PowerSource) -> Void) {
        lock.withLock { self.onChange = onChange }
        // Unretained: `stop()` invalidates the source before this object can go, and the
        // holder keeps it alive until then.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            monitor.fire()
        }, context)?.takeRetainedValue() else { return }
        lock.withLock { runLoopSource = source }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    public func stop() {
        let source: CFRunLoopSource? = lock.withLock {
            onChange = nil
            defer { runLoopSource = nil }
            return runLoopSource
        }
        // Invalidate is thread-safe and removes it from every run loop; a callback already
        // dequeued finds `onChange` nil.
        if let source { CFRunLoopSourceInvalidate(source) }
    }

    deinit { stop() }

    private func fire() {
        guard let onChange = lock.withLock({ self.onChange }) else { return }
        onChange(current)
    }
}

public struct DarwinConsoleSession: ConsoleSessionProbing {
    public init() {}

    public func current() -> ConsoleSession {
        Self.parse(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// The lock flag is the undocumented `CGSSessionScreenIsLocked` key; it is absent (not
    /// false) when unlocked. No dictionary at all means hostd is outside any GUI session, a
    /// LaunchDaemon or ssh-only login, where a screen run has no screen.
    public static func parse(_ dict: [String: Any]?) -> ConsoleSession {
        guard let dict else { return ConsoleSession(supported: true, consoleUser: false, locked: false) }
        let onConsole = dict[kCGSessionOnConsoleKey] as? Bool ?? false
        let loginDone = dict[kCGSessionLoginDoneKey] as? Bool ?? false
        let consoleUser = onConsole && loginDone
        let locked = consoleUser && (dict["CGSSessionScreenIsLocked"] as? Bool ?? false)
        return ConsoleSession(supported: true, consoleUser: consoleUser, locked: locked)
    }
}
#endif
