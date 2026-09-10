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

    /// The ticker's own in-flight pass, if any — so `passNow()` can wait it out rather than
    /// race it. Only `tick()` creates one; `passNow()` never assigns here, since it is not a
    /// ticker pass itself.
    private var inFlight: Task<Void, Never>?

    /// Seeded at construction rather than left nil, so the *first* pass waits a window too.
    ///
    /// Deliberate: the reconciler is created the moment a codex tab appears, and a tab that
    /// was just created or just restored is pinned to the thread it has only now negotiated —
    /// there is nothing for a pass to find. Where an immediate pass genuinely is needed, the
    /// caller asks for one outright through `passNow()` (`resumeRestoredCodex` does, so a
    /// relaunch lands on the right thread without waiting a tick).
    ///
    /// A tab restored *at relaunch* is the exception to "nothing for a pass to find", which is
    /// why that caller's pass runs before it types `codex resume <id>` rather than after: its
    /// pin was negotiated in some previous run, and the user may have abandoned that thread for
    /// another one at any point since.
    ///
    /// Relaunch and no other path: `resumeRestoredCodex` takes the pass only under
    /// `pinsPredateThisRun`, and its reopen callers — ⌘⇧T and the phone's
    /// `reopenClosedSession`, both through `settleReopen` — pass false. Their pin is a thread
    /// the user chose seconds ago, so it is current by construction; moving it to the
    /// directory's newest thread would override the choice instead of repairing a stale one.
    ///
    /// ⌘K's `openConversation` passes false as well, but it is not a case that happens: it
    /// resolves its login with `launchAccount(for: .claude, …)` and builds its `Session` with
    /// no `agent:` argument, so nothing it makes ever defers into `resumeRestoredCodex`. That
    /// argument is an answer held ready, not one in use.
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

    /// One pass now, off the schedule, stamping the window as a tick would.
    ///
    /// `resumeRestoredCodex`'s stage 2 is the only caller, and it cannot wait for a tick: its
    /// tabs' pins came off disk, and it is about to type `codex resume <id>` at every one of
    /// them. It used to call `SessionStore.reconcileCodexPins()` straight, which reconciled
    /// exactly the same — the stamp is the whole reason this exists.
    ///
    /// **Why the stamp still matters, now that `inFlight` and `isPolling` handle the passes
    /// this one could overlap.** The reconciler is constructed inside that method's stage 1
    /// (`preparedAdapter`), so `lastPass` is seeded there and, without this stamp, the first
    /// tick would fall due a window after *that* instant — which an unstarted or wedged
    /// app-server can easily outlast, since the pass below spends a whole `readTimeout` on each
    /// group it cannot reach. A tick landing that soon after `passNow()` returns is a *later*
    /// re-pin arriving while stage 3 is mid-restore: it reads a tab's binding before awaiting
    /// `rebind` and types what it read, so a pass that moves the record across that suspension
    /// leaves the terminal on the pre-tick thread — the record-versus-terminal split the
    /// reorder exists to remove, re-entered from the other side. The stamp is what pushes that
    /// later tick a full window past this pass instead.
    ///
    /// **Stamped at the end, unlike `tick()`.** There the window means "how often we ask" and
    /// stamping late would let a slow app-server stretch the cadence without bound. Here there
    /// is no cadence to stretch — one pass, at a caller's request — and the window that has to
    /// be clear is the one *after* it, the stretch of stage 3 where the sends happen. Stamping
    /// at the start would leave that stretch a window shorter, by however long this pass took.
    ///
    /// **When this returns, no reconcile pass is in flight and none starts for a window.**
    /// Three pieces make that true, one per way a pass could otherwise overlap stage 3:
    /// `await inFlight?.value` first, so a ticker pass already running when this is called is
    /// waited out rather than raced — it cannot still be running once this returns. `isPolling`
    /// is then set for the duration of this pass (restored on the way out only if this call is
    /// the one that set it, via `wasPolling`), so a tick that lands *during* this pass sees the
    /// guard held and does not start a second, concurrent one. And the stamp below, as always,
    /// pushes the *next* tick a full window past this pass. Together they close the pass this
    /// method could still be racing with, the pass a tick could start underneath it, and the
    /// pass the very next tick could start after it.
    func passNow() async {
        await inFlight?.value
        let wasPolling = isPolling
        isPolling = true
        defer { if !wasPolling { isPolling = false } }
        await reconcile()
        lastPass = now()
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
        inFlight = Task { [weak self] in
            guard let self else { return }
            await self.reconcile()
            self.isPolling = false
            self.inFlight = nil
        }
    }
}
