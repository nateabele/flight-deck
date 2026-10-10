import Foundation

// "Keep this Mac awake while plugged in", the Hosting setting a macOS host holds for itself.
//
// Why it exists: a host that runs UI tests (XCUITest) must not lock its screen between runs. A
// locked session (`CGSSessionScreenIsLocked`) fails every launch with "Failed to activate
// application … Running Background", and the lock follows idle display sleep or the screen
// saver when "require password" is on. Holding both idle assertions while on AC keeps either
// from starting, without changing a system setting (no pmset writes, no sudo).
//
// The logic lives here, Foundation-only, so it is tested against fakes; the IOKit power-source
// watcher is `IOKitPowerSource` in HostKitDarwin, and only the macOS hostd wires one in. A Linux
// host has no display to keep on and answers the admin requests with `failed`.

/// What is powering the machine right now.
public enum PowerSource: String, Codable, Sendable, Equatable {
    case ac
    case battery
    /// The source could not be read. Never treated as AC: keeping a laptop awake on battery is
    /// the failure this option must never cause.
    case unknown

    /// A spelling a later hostd adds reads as `unknown`, so a newer host never fails the whole
    /// reply in an older app.
    public init(from decoder: any Decoder) throws {
        self = PowerSource(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// The seam over IOKit's power-source notification, so tests drive AC/battery transitions.
public protocol PowerSourceMonitoring: AnyObject, Sendable {
    var current: PowerSource { get }
    /// Calls `onChange` after every power-source change, possibly with the same source again
    /// (IOKit notifies on a battery-percentage tick too). Called at most once.
    func start(onChange: @escaping @Sendable (PowerSource) -> Void)
    func stop()
}

/// The admin reply's payload: the setting, and whether it is holding right now.
public struct KeepAwakeStatus: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let holding: Bool
    public let power: PowerSource

    public init(enabled: Bool, holding: Bool, power: PowerSource) {
        self.enabled = enabled
        self.holding = holding
        self.power = power
    }
}

/// Holds an idle-system-sleep and an idle-display-sleep assertion exactly while the option is
/// on and the machine is on AC, re-deciding on every power-source change.
///
/// "User idle" assertions, like a delegated run's: a lid close, an explicit Sleep or a manual
/// lock (⌃⌘Q) still win. Those are the user's call, and no assertion can stop them anyway.
///
/// Thread-safe: hostd calls `setEnabled` on the admin socket's thread and IOKit calls back on
/// the main run loop.
public final class KeepAwakeHolder: @unchecked Sendable {
    /// What `pmset -g assertions` shows, so whoever wonders why the Mac never sleeps finds us.
    public static let assertionName = "Flight Deck hosting: keep awake while plugged in"

    private let power: any PowerAsserting
    private let source: any PowerSourceMonitoring
    private let lock = NSLock()
    private var enabled: Bool
    private var lastSource: PowerSource = .unknown
    private var held: [PowerAssertion] = []
    private var finished = false

    public init(power: any PowerAsserting, source: any PowerSourceMonitoring, enabled: Bool) {
        self.power = power
        self.source = source
        self.enabled = enabled
        // Watch first, then read: a change landing between the two is then seen by the
        // callback rather than lost behind a stale read.
        source.start { [weak self] in self?.powerChanged($0) }
        powerChanged(source.current)
    }

    deinit {
        // A dropped holder must not leave the Mac unable to sleep for the life of hostd.
        for assertion in held { assertion.release() }
    }

    public var status: KeepAwakeStatus {
        lock.withLock { KeepAwakeStatus(enabled: enabled, holding: !held.isEmpty, power: lastSource) }
    }

    public func setEnabled(_ on: Bool) {
        lock.withLock {
            guard !finished else { return }
            enabled = on
            reconcile()
        }
    }

    /// Releases everything and stops watching; later changes and `setEnabled` do nothing. hostd
    /// calls it on SIGTERM. (IOKit drops a dead process's assertions too, so a crash cannot
    /// strand them either.)
    public func shutdown() {
        let wasRunning: Bool = lock.withLock {
            guard !finished else { return false }
            finished = true
            reconcile()
            return true
        }
        if wasRunning { source.stop() }
    }

    private func powerChanged(_ now: PowerSource) {
        lock.withLock {
            guard !finished else { return }
            lastSource = now
            reconcile()
        }
    }

    /// Under `lock`. Takes the pair only when none is held, so a repeated AC notification
    /// never stacks a second pair that would need its own release.
    private func reconcile() {
        let want = enabled && !finished && lastSource == .ac
        if want, held.isEmpty {
            held = [power.hold(.idleSleep, reason: Self.assertionName),
                    power.hold(.displaySleep, reason: Self.assertionName)]
        } else if !want, !held.isEmpty {
            for assertion in held { assertion.release() }
            held = []
        }
    }
}

/// Host-side settings the app's Hosting tab writes through the admin socket:
/// `<HostStateRoot>/hosting.json`. They live with hostd, not in the app's defaults, because
/// hostd applies them while the app is not running.
public struct HostingSettings: Codable, Sendable, Equatable {
    public static let fileName = "hosting.json"

    public var keepAwakeWhilePluggedIn: Bool

    public init(keepAwakeWhilePluggedIn: Bool = false) {
        self.keepAwakeWhilePluggedIn = keepAwakeWhilePluggedIn
    }

    /// A missing key reads as its default, so a file from an older build still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepAwakeWhilePluggedIn = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeWhilePluggedIn) ?? false
    }

    /// Missing or unreadable reads as the defaults: a damaged file must not stop hosting.
    public static func load(root: URL) -> HostingSettings {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
              let settings = try? JSONDecoder().decode(HostingSettings.self, from: data) else {
            return HostingSettings()
        }
        return settings
    }

    /// Atomic, so a crash mid-write leaves the old file rather than half a new one; 0600 like
    /// everything else under the state root.
    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = root.appendingPathComponent(Self.fileName)
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
