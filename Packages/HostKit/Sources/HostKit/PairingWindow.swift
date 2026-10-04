import Foundation

/// One pairing window at a time; arming again replaces it (Review Focus 3), so a stale code a
/// user abandoned can never pair a controller after a fresh one was shown.
///
/// The code is held as text because `PairingCode` lives in FleetKit/PairingCore, not HostKit:
/// each hostd mints its own and passes `formatted` in.
public final class PairingWindow: @unchecked Sendable {
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval
    private let lock = NSLock()
    private var armed: (code: String, expiresAt: Date)?

    public init(now: @escaping @Sendable () -> Date = Date.init, lifetime: TimeInterval = 120) {
        self.now = now
        self.lifetime = lifetime
    }

    @discardableResult
    public func arm(codeText: String) -> Date {
        lock.lock(); defer { lock.unlock() }
        let expiresAt = now().addingTimeInterval(lifetime)
        armed = (codeText, expiresAt)
        return expiresAt
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        armed = nil
    }

    /// nil once expired, so a status poll never advertises a window that can no longer pair.
    public var current: (code: String, expiresAt: Date)? {
        lock.lock(); defer { lock.unlock() }
        return live()
    }

    /// True once, for the live code. The window closes on success so one code pairs exactly one
    /// controller; a wrong guess leaves it open so a typo does not cost the user the window.
    public func consume(codeText: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let a = live(), Self.normalize(a.code) == Self.normalize(codeText) else { return false }
        armed = nil
        return true
    }

    /// Caller holds the lock.
    private func live() -> (code: String, expiresAt: Date)? {
        guard let a = armed else { return nil }
        if now() >= a.expiresAt { armed = nil; return nil }
        return a
    }

    /// A code is typed by hand, so case and dashes must not decide whether it matches.
    private static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0 != "-" }
    }
}
