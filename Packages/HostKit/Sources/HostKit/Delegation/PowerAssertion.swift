import Foundation

// Keeping the host awake while it works (spec §6.1, §6.3). A run that sleeps with the host is
// a run that never reports its exit: every run holds an idle-sleep assertion, and a screen run
// also keeps the display on, because a UI test against a sleeping display fails in ways that
// look like test bugs.
//
// The macOS assertion is IOKit, which HostKit may not import (Foundation-only, so the Linux
// hostd builds from the same sources); it lives in HostKitDarwin's `IOKitPowerAssertions`, and
// hostd injects it. The Linux one, a `systemd-inhibit` child, is plain Foundation and lives here.

public enum PowerAssertionKind: Sendable, Equatable {
    /// Keeps the machine from idle-sleeping. Held by every run.
    case idleSleep
    /// Keeps the display on. Held by a screen run while it holds the screen lease.
    case displaySleep
}

/// One held assertion. `release` is idempotent, because a run's exit and its cancel can both
/// reach it, and releasing an IOKit assertion twice would drop someone else's reference.
public final class PowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?

    public init(release: @escaping @Sendable () -> Void) {
        onRelease = release
    }

    /// Holds nothing.
    public static func none() -> PowerAssertion { PowerAssertion {} }

    public func release() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            defer { onRelease = nil }
            return onRelease
        }
        action?()
    }

    deinit { onRelease?() }
}

public protocol PowerAsserting: Sendable {
    /// Never fails: a host that cannot keep itself awake still runs the command, it just might
    /// sleep through it. `reason` shows up in `pmset -g assertions` / `systemd-inhibit --list`.
    func hold(_ kind: PowerAssertionKind, reason: String) -> PowerAssertion
}

/// For a host with no mechanism, and the HostKit default on macOS (where hostd injects
/// `IOKitPowerAssertions` from HostKitDarwin).
public struct NoPowerAssertions: PowerAsserting {
    public init() {}
    public func hold(_ kind: PowerAssertionKind, reason: String) -> PowerAssertion { .none() }
}

/// Linux: a `systemd-inhibit --what=sleep … cat` child per assertion, when systemd-inhibit is
/// installed.
///
/// The child is `cat` reading a pipe from hostd, not `sleep infinity` killed by pid: releasing
/// closes the pipe, `cat` exits, and so does the inhibitor. The same happens if hostd dies, so
/// a crash can never leave the host unable to sleep. (Killing `systemd-inhibit` instead would
/// orphan its `sleep infinity`.)
///
/// Only idle sleep is inhibited: Linux refuses screen runs in v1, so there is no display to
/// keep on.
public struct SystemdInhibitAssertions: PowerAsserting {
    private let executable: String?

    public init(executable: String? = SystemdInhibitAssertions.locate()) {
        self.executable = executable
    }

    public static func locate() -> String? {
        ["/usr/bin/systemd-inhibit", "/bin/systemd-inhibit"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func hold(_ kind: PowerAssertionKind, reason: String) -> PowerAssertion {
        guard kind == .idleSleep, let executable else { return .none() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["--what=sleep", "--who=flightdeck-hostd", "--why=\(reason)", "--mode=block", "cat"]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .none() }
        let writer = stdin.fileHandleForWriting
        // `p` is captured so the Process object lives until release; Foundation reaps it.
        return PowerAssertion { [p] in
            _ = p
            try? writer.close()
        }
    }
}

extension PowerAssertion {
    /// What HostKit can offer on its own: systemd-inhibit on Linux, nothing on macOS (hostd
    /// passes HostKitDarwin's `IOKitPowerAssertions` there).
    public static var platformDefault: any PowerAsserting {
        #if os(Linux)
        SystemdInhibitAssertions()
        #else
        NoPowerAssertions()
        #endif
    }
}
