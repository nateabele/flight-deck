import Foundation

/// The host's single screen (spec §6.3): one run holds it, the rest wait first come, first
/// served. Two UI-test runs sharing a display steal each other's focus and both fail, so a
/// second screen run queues instead of colliding, and its CLI can name who it waits on.
///
/// Releasing is the only way out of the queue, for the holder and a waiter alike, and it is
/// idempotent: a cancelled waiter that stayed queued would block every run behind it forever.
public final class ScreenLease: @unchecked Sendable {
    private struct Waiter {
        let id: String
        let holder: LeaseHolder
        let granted: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var current: Waiter?
    private var waiting: [Waiter] = []
    private var observers: [@Sendable () -> Void] = []

    public init() {}

    /// Joins the queue. Returns 0 when granted at once (and `granted` has already run), or the
    /// 1-based queue position. `granted` runs off the lease's lock, so it may call back in.
    public func request(_ id: String, holder: LeaseHolder, granted: @escaping @Sendable () -> Void) -> Int {
        let waiter = Waiter(id: id, holder: holder, granted: granted)
        let (position, grant): (Int, Waiter?) = lock.withLock {
            if current == nil {
                current = waiter
                return (0, waiter)
            }
            waiting.append(waiter)
            return (waiting.count, nil)
        }
        grant?.granted()
        notify()
        return position
    }

    /// Releases the lease if `id` holds it (granting the next waiter), or leaves the queue if
    /// it is waiting. A no-op otherwise.
    public func release(_ id: String) {
        let (changed, grant): (Bool, Waiter?) = lock.withLock {
            if current?.id == id {
                current = waiting.isEmpty ? nil : waiting.removeFirst()
                return (true, current)
            }
            guard let i = waiting.firstIndex(where: { $0.id == id }) else { return (false, nil) }
            waiting.remove(at: i)
            return (true, nil)
        }
        grant?.granted()
        if changed { notify() }
    }

    /// 0 for the holder, the 1-based queue position for a waiter, nil otherwise.
    public func position(of id: String) -> Int? {
        lock.withLock {
            if current?.id == id { return 0 }
            return waiting.firstIndex { $0.id == id }.map { $0 + 1 }
        }
    }

    public var holder: LeaseHolder? { lock.withLock { current?.holder } }
    public var queued: Int { lock.withLock { waiting.count } }

    /// Called after every change of holder or queue, so queued runs can report their new
    /// position.
    public func observe(_ onChange: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(onChange) }
    }

    private func notify() {
        for observer in lock.withLock({ observers }) { observer() }
    }
}
