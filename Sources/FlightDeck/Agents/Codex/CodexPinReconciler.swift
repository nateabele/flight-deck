import Foundation

/// Schedules `SessionStore.reconcileCodexPins()`, and does nothing else.
///
/// **Why this exists.** Claude has a status registry, so a conversation the user changes by
/// hand — a `/resume` typed into the TUI — reaches the store as a registry row and
/// `ConversationPin.resolve` follows it. Codex has no registry at all. A user who types
/// `codex` at a Flight Deck tab's shell gets a brand-new thread, and nothing tells the store:
/// the session record stays pinned to the thread the tab was created with, the rollout watcher
/// keeps tailing that thread's file, and the tab reads as empty on the Mac and on the phone.
/// Measured on the live machine: a tab driving a 676-line thread while its record pinned a
/// different one whose rollout was one line long and three days stale.
///
/// **Why it is a scheduler and nothing more.** Every reconcile decision lives in
/// `SessionStore.reconcileCodexPins()`, which is directly callable and needs no clock, so the
/// rules are testable without expectations. What is left here — subscription, re-entrancy,
/// throttling — is testable by calling `tick()` with no clock at all.
///
/// **Why it is its own object rather than a `clock.add(self)` from the store.**
/// `WatchClock.add` keys subscribers by `ObjectIdentifier(owner)` and *replaces* a matching
/// entry rather than adding a second one, so a store-owned subscription would silently evict
/// (or be evicted by) any other subscription the store registers under itself.
@MainActor
final class CodexPinReconciler {
    /// How long a pass has to be old before another one may start.
    ///
    /// On top of the clock's own cadence (500 ms in the foreground), because a pass is not a
    /// file read like every other `WatchClock` subscriber: it is one `thread/list` JSON-RPC
    /// round trip per distinct codex directory, and the thing it is watching for — a human
    /// typing `codex` at a shell prompt — does not need sub-second latency.
    static let throttle: Duration = .seconds(5)

    private weak var clock: WatchClock?
    private let reconcile: () async -> Void

    /// Injectable rather than a direct `ContinuousClock.now` read, so the throttle is
    /// assertable without sleeping. None of the sibling watchers in this directory throttle at
    /// all — they poll files, which is cheap enough to do every beat — so there is no house
    /// pattern to follow here; this is the smallest seam that makes the window testable.
    /// `ContinuousClock` and not `Date`: a throttle must not be movable by a clock adjustment.
    private let now: () -> ContinuousClock.Instant

    /// Re-entrancy guard, exactly as `CodexRolloutWatcher.poll` keeps one and for the same
    /// reason: a pass that outlives its tick must be dropped rather than queued. Here that
    /// matters more than there — a queued pass would pile up RPC round trips behind an
    /// app-server that has gone quiet, and the one in flight is already asking the question
    /// the next one would ask.
    private var isPolling = false

    /// Seeded at construction rather than left nil, so the *first* pass waits a window too.
    ///
    /// Deliberate: the reconciler is created the moment a codex tab appears, and a tab that
    /// was just created or just restored is pinned to the thread it has only now negotiated —
    /// there is nothing for a pass to find. Where an immediate pass genuinely is needed, the
    /// caller asks for one outright (`resumeRestoredCodex` does, so a relaunch lands on the
    /// right thread without waiting a tick).
    private var lastPass: ContinuousClock.Instant

    init(
        clock: WatchClock?,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        reconcile: @escaping () async -> Void
    ) {
        self.clock = clock
        self.now = now
        self.reconcile = reconcile
        self.lastPass = now()
    }

    func start() {
        clock?.add(self) { [weak self] in self?.tick() }
    }

    func stop() {
        clock?.remove(self)
    }

    /// One beat. Internal rather than private so tests can drive the two guards synchronously
    /// against a fake now-provider, the way `WatchClock.fire()` and `TranscriptWatcher.drain()`
    /// are internal for the same reason.
    func tick() {
        guard !isPolling else { return }
        let now = self.now()
        guard now - lastPass >= Self.throttle else { return }
        // Stamped at the *start* of the pass, not its end: the window is "how often we ask",
        // and stamping at the end would let a slow app-server stretch it without bound.
        lastPass = now
        isPolling = true
        Task { [weak self] in
            guard let self else { return }
            await self.reconcile()
            self.isPolling = false
        }
    }
}
