import Foundation

/// How long this host has had nothing to do, for `host.info`'s `idleSince` (spec §7.3): the
/// controller's reaper stops a cloud box that has sat idle past its threshold, so the box
/// must never look idle while it is working and never look busy forever once it is not.
///
/// Activity is counted, not flagged: a run, a service and a sync overlap freely, and the host
/// is idle only once the last of them has ended. A token per activity rather than a bare
/// counter, so an `end` that arrives twice (a run's watcher racing a shutdown) or for an
/// activity this tracker never began cannot drive the count below zero and report a busy
/// host as idle.
public final class IdleTracker: @unchecked Sendable {
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var open: Set<UUID> = []
    /// When the last activity ended or the last request arrived. Starts at creation: a hostd
    /// that just booted has been idle since it booted, not since 1970, so a fresh box is
    /// not reaped before anyone has had a chance to use it.
    private var last: Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        last = now()
    }

    /// An activity started (a run, a service, a sync). Hand the token to `end`.
    public func begin() -> UUID {
        let token = UUID()
        lock.withLock { _ = open.insert(token) }
        return token
    }

    /// The activity `token` ended. An unknown or already-ended token changes nothing.
    public func end(_ token: UUID) {
        let at = now()
        lock.withLock {
            guard open.remove(token) != nil else { return }
            last = at
        }
    }

    /// A request arrived: the host is in use even if the request starts nothing.
    public func touch() {
        let at = now()
        lock.withLock { last = at }
    }

    /// When the host last became idle; nil while any activity is open.
    public var idleSince: Date? {
        lock.withLock { open.isEmpty ? last : nil }
    }
}
