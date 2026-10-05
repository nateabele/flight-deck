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
