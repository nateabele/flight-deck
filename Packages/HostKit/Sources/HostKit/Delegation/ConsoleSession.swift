import Foundation

// Whether the host's screen is usable for a screen run (spec §6.3, §7 step 6). A UI test
// started with nobody logged in at the console, or behind the lock screen, fails in ways that
// look like test bugs, so the preflight refuses it with a reason instead.
//
// The macOS probe reads `CGSessionCopyCurrentDictionary`, which is CoreGraphics and so lives in
// HostKitDarwin (`DarwinConsoleSession`); HostKit stays Foundation-only. Linux refuses screen
// runs in v1.

public struct ConsoleSession: Sendable, Equatable {
    /// False where screen runs are refused outright (Linux in v1).
    public var supported: Bool
    /// A user is logged in and on the console (not switched away by fast user switching).
    public var consoleUser: Bool
    public var locked: Bool

    public init(supported: Bool, consoleUser: Bool, locked: Bool) {
        self.supported = supported
        self.consoleUser = consoleUser
        self.locked = locked
    }

    public static let unsupported = ConsoleSession(supported: false, consoleUser: false, locked: false)

    /// HostKit's own probe: unsupported everywhere. On macOS hostd injects HostKitDarwin's
    /// `DarwinConsoleSession` instead.
    public static var platformDefault: any ConsoleSessionProbing { UnsupportedConsoleSession() }
}

public protocol ConsoleSessionProbing: Sendable {
    /// Read fresh on every call: the screen locks and unlocks under a long-lived hostd.
    func current() -> ConsoleSession
}

public struct UnsupportedConsoleSession: ConsoleSessionProbing {
    public init() {}
    public func current() -> ConsoleSession { .unsupported }
}
