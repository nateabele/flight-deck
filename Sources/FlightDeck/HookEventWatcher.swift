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

    private var offset: UInt64
    private var hasChosenStart: Bool
    private var readiness: [UUID: ComposerReadiness] = [:]

    init(
        directory: URL,
        clock: WatchClock?,
        onChange: @escaping ([UUID: ComposerReadiness]) -> Void
    ) {
        let url = directory.appendingPathComponent("events.ndjson")
        self.url = url
        self.clock = clock
        self.onChange = onChange

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

    /// Reads everything appended since the last call. Synchronous, so tests need no
    /// expectations — the seam `TranscriptWatcher.drain()` establishes.
    func drain() {
        let tail = TailReader.read(
            url: url, offset: offset, hasChosenStart: hasChosenStart, truncation: .resumeAtEnd
        )
        offset = tail.offset
        hasChosenStart = tail.hasChosenStart

        var changes: [UUID: ComposerReadiness] = [:]
        for line in tail.lines {
            guard let record = HookEventRecord.decode(line) else { continue }
            let current = readiness[record.sessionID] ?? .unknown
            let next = ComposerReadiness.applying(record.event, to: current)
            guard next != current else { continue }
            readiness[record.sessionID] = next
            changes[record.sessionID] = next
        }
        guard !changes.isEmpty else { return }
        onChange(changes)
    }
}
