import Foundation

/// Tails the shared hook-event log and reports each session's `ComposerReadiness`.
///
/// **One watcher for the whole app, not one per tab** — the same shape as
/// `SessionStatusWatcher`, and for the same reason: the log is a single shared file, so a
/// per-tab watcher would re-read it N times per tick. Fan-out happens downstream, keyed by
/// the `session_id` in each record.
///
/// `TailTruncationPolicy.resumeAtEnd` is the policy for a shared append-only log: a shrink
/// means the file was rotated by another writer, and restarting from zero would replay
/// every session's history as if it were new.
///
/// **The first look happens eagerly, in `init`, not on the first scheduled `drain()`.**
/// `SessionReaper` tears sessions down by signal escalation (SIGHUP → SIGTERM → SIGKILL),
/// not a graceful exit, so a dead session's last-logged readiness is frequently `.live`,
/// never `.absent`. Session ids are stable across resume — `session_id` is the same
/// conversation UUID Flight Deck passes as `--session-id` next launch — so replaying that
/// stale `.live` would attach it to the *resumed* tab and read as ready while the new
/// process is still booting, suppressing the `.unknown` → legacy-screen-grammar fallback
/// during exactly the window it exists to cover. Deciding "start at EOF" against the log as
/// it exists at construction, rather than whenever the clock happens to schedule the first
/// `drain()`, is what keeps a backlog already on disk from being mistaken for news: a file
/// that does not exist yet at construction has no backlog to skip either way, so this only
/// changes behavior when a stale log is already there.
@MainActor
final class HookEventWatcher {
    private let url: URL
    private weak var clock: WatchClock?
    private let onChange: ([UUID: ComposerReadiness]) -> Void
    private let onDialog: ([DialogAttribution.Change]) -> Void
    private var attribution = DialogAttribution()

    private var offset: UInt64
    private var hasChosenStart: Bool
    private var readiness: [UUID: ComposerReadiness] = [:]

    init(
        directory: URL,
        clock: WatchClock?,
        onChange: @escaping ([UUID: ComposerReadiness]) -> Void,
        onDialog: @escaping ([DialogAttribution.Change]) -> Void = { _ in }
    ) {
        let url = directory.appendingPathComponent("events.ndjson")
        self.url = url
        self.clock = clock
        self.onChange = onChange
        self.onDialog = onDialog

        // The first look, taken now rather than deferred to the first drain() — see the
        // type doc comment. `hasChosenStart: false` is what makes TailReader treat any
        // backlog already on disk as history and jump straight to its current end; a file
        // that doesn't exist yet returns `hasChosenStart: true` regardless, so later
        // content still arrives from byte 0 once the file is created.
        let firstLook = TailReader.read(
            url: url, offset: 0, hasChosenStart: false, truncation: .resumeAtEnd
        )
        self.offset = firstLook.offset
        self.hasChosenStart = firstLook.hasChosenStart
    }

    func start() {
        clock?.add(self) { [weak self] in self?.drain() }
    }

    func stop() {
        clock?.remove(self)
    }

    /// Drops what this watcher remembers about one session, so the next event for it is
    /// reported as news rather than swallowed as unchanged.
    ///
    /// **Without this, the change-only emission in `drain()` below makes a reset one-way, and
    /// the feature switches itself off.** `SessionStore` demotes a tab's readiness when it
    /// loses its status-registry anchor — to `.absent` when a syscall confirms the process it
    /// was following is gone, to `.unknown` otherwise — regardless of what this map last held
    /// for it, `.live` included but not required: a tab whose hook feed never reported
    /// anything, only ever anchored through a registry row, is demoted the same way on that
    /// row's pid dying. Neither agent reliably announces its own death, and the deaths this
    /// demotion exists for are exactly the ones that log no `SessionEnd`, so for a tab this map
    /// DOES hold `.live` for, it is still holding it when the demotion happens. A claude
    /// resumed in that tab reuses the same `session_id` (see the type doc above), so its
    /// `SessionStart` folds to `.live`, compares equal to what is remembered here, and is never
    /// emitted: the store keeps whatever the demotion left it on for the rest of the process's
    /// life — stranded on the legacy screen grammar after a `.unknown`, and refusing every
    /// injection after an `.absent`, which is the worse of the two and the reason this is not
    /// merely a nicety.
    ///
    /// The dedup itself stays — it is what keeps an idle log from re-announcing `.live` into
    /// the store on every tick. Only the store's own demotions punch through it, and they are
    /// the one caller that positively knows this memory is stale.
    func forget(_ sessionID: UUID) {
        readiness.removeValue(forKey: sessionID)
    }

    /// What this watcher currently remembers for a session, or nil if it remembers nothing.
    /// A read, for the suite to assert that a store-side reset and this map cannot disagree.
    func rememberedReadinessForTesting(_ sessionID: UUID) -> ComposerReadiness? {
        readiness[sessionID]
    }

    /// Reads everything appended since the last call. Synchronous, so tests need no
    /// expectations — the seam `TranscriptWatcher.drain()` establishes.
    func drain() {
        let tail = TailReader.read(
            url: url, offset: offset, hasChosenStart: hasChosenStart, truncation: .resumeAtEnd
        )
        offset = tail.offset
        hasChosenStart = tail.hasChosenStart

        var changes: [UUID: ComposerReadiness] = [:]
        var dialogChanges: [DialogAttribution.Change] = []
        for line in tail.lines {
            guard let record = HookEventRecord.decode(line) else { continue }
            if let change = attribution.apply(record) { dialogChanges.append(change) }
            let current = readiness[record.sessionID] ?? .unknown
            let next = ComposerReadiness.applying(record.event, to: current)
            guard next != current else { continue }
            readiness[record.sessionID] = next
            changes[record.sessionID] = next
        }
        // Before the readiness early return: a PermissionRequest never changes readiness.
        if !dialogChanges.isEmpty { onDialog(dialogChanges) }
        guard !changes.isEmpty else { return }
        onChange(changes)
    }
}
