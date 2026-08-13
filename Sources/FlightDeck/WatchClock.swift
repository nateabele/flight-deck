import AppKit
import Foundation

/// The single periodic timer behind every file poll in the app.
///
/// **Why one timer.** Each `TranscriptWatcher` used to own a 500 ms `DispatchSourceTimer`,
/// scheduled from `.now()` at the moment its session was created. Their phases were
/// therefore uncorrelated, so eight tabs meant eight wakeups scattered across each second
/// plus the status watcher's — nine unsynchronised timers where one would do. Registering
/// here collapses that to a single wakeup that runs every subscriber back to back.
///
/// **Why leeway.** A `DispatchSourceTimer` scheduled without `leeway:` asks for maximum
/// precision, which keeps the CPU out of its deeper idle states. Nothing here has a
/// deadline — these are file polls whose results feed a sidebar — so the timer publishes a
/// wide tolerance and lets the kernel align it with work the system was going to wake for
/// anyway.
///
/// **Why throttled rather than suspended in the background.** Tempting, but wrong here:
/// `SessionNotificationPolicy` only ever returns `.notify` when the app is *inactive*, so
/// the background poll is precisely what makes "your agent needs input" notifications
/// work. Suspending it would silently remove the feature. Slowing it trades up to a second
/// and a half of notification latency — imperceptible for a prompt that is waiting on a
/// human — for a 4× cut in idle wakeups.
@MainActor
final class WatchClock {
    /// Matches the cadence the watchers used to schedule individually.
    static let foregroundInterval: Duration = .milliseconds(500)
    /// Background cadence. See the note above on why this is a throttle, not a suspension.
    static let backgroundInterval: Duration = .seconds(2)
    /// Half the foreground period. Wide enough for the kernel to coalesce this with other
    /// timers, far short of the point where a poll feels laggy.
    static let leeway: Duration = .milliseconds(250)

    /// The cadence for a given activation state. Split out so the decision is assertable
    /// without standing up a timer.
    static func interval(forActive active: Bool) -> Duration {
        active ? foregroundInterval : backgroundInterval
    }

    /// A registered poll.
    ///
    /// `owner` is weak so a watcher that is dropped without `stop()` — a session closing
    /// on a path that forgets to unregister — takes its entry with it on the next beat.
    /// Each watcher used to own its timer and cancel it in `deinit`, which made that
    /// self-healing automatic; keeping the reference weak preserves the property now that
    /// registration outlives the object.
    private struct Subscriber {
        let id: ObjectIdentifier
        weak var owner: AnyObject?
        let tick: () -> Void
    }

    /// Insertion-ordered so ticks run in a stable, debuggable order. A dictionary would
    /// leave the status scan and the transcript reads racing for position each tick.
    private var subscribers: [Subscriber] = []

    private var timer: DispatchSourceTimer?
    /// The cadence `timer` was built with, so a redundant activation does not rebuild it.
    private var currentInterval: Duration?

    private var observers: [NSObjectProtocol] = []

    /// Test seam. Production reads `NSApplication`; tests construct a clock with no
    /// subscribers and never start a timer at all.
    ///
    /// Typed `@MainActor` because the production default reads `NSApplication.shared`,
    /// which is main-actor isolated — an unannotated closure default argument is evaluated
    /// in a nonisolated context and would warn.
    private let appIsActive: @MainActor () -> Bool

    init(appIsActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive }) {
        self.appIsActive = appIsActive

        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reschedule() }
                }
            )
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
    }

    /// Registers `tick` to run on every beat. Re-registering the same owner replaces its
    /// closure rather than adding a second one, so a watcher restarted in place cannot end
    /// up polled twice per beat.
    func add(_ owner: AnyObject, _ tick: @escaping () -> Void) {
        let id = ObjectIdentifier(owner)
        let subscriber = Subscriber(id: id, owner: owner, tick: tick)
        if let at = subscribers.firstIndex(where: { $0.id == id }) {
            subscribers[at] = subscriber
        } else {
            subscribers.append(subscriber)
        }
        reschedule()
    }

    func remove(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        subscribers.removeAll { $0.id == id }
        reschedule()
    }

    /// Starts, stops, or re-paces the timer to match the current subscriber count and
    /// activation state. Idempotent — safe to call on every registration and every
    /// activation change.
    private func reschedule() {
        guard !subscribers.isEmpty else {
            timer?.cancel()
            timer = nil
            currentInterval = nil
            return
        }

        let interval = Self.interval(forActive: appIsActive())
        guard interval != currentInterval else { return }

        timer?.cancel()
        let period = interval.dispatchInterval
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(
            deadline: .now() + period,
            repeating: period,
            leeway: Self.leeway.dispatchInterval
        )
        t.setEventHandler { [weak self] in self?.fire() }
        timer = t
        currentInterval = interval
        t.resume()
    }

    /// One beat. Internal rather than private so tests can drive registration, replacement,
    /// and pruning synchronously instead of sleeping for a real timer — the same seam
    /// `SessionStatusWatcher.drain()` exposes for the same reason.
    func fire() {
        // Drop entries whose owner is gone before ticking, so an unbalanced `start()` costs
        // one wasted beat rather than a permanent one.
        subscribers.removeAll { $0.owner == nil }

        // `subscribers` is an array, so this iterates a copy: a tick that unregisters a
        // watcher — a session closing as its own read is applied — cannot invalidate the
        // iteration underneath us. `reschedule()` from inside a tick is likewise safe.
        for subscriber in subscribers { subscriber.tick() }

        if subscribers.isEmpty { reschedule() }
    }
}

private extension Duration {
    /// GCD still speaks `DispatchTimeInterval`. The cadences above are `Duration` because
    /// that type is `Comparable` and directly assertable; this is the one conversion.
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
