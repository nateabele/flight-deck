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
@MainActor
final class HookEventWatcher {
    private let url: URL
    private weak var clock: WatchClock?
    private let onChange: ([UUID: ComposerReadiness]) -> Void

    private var offset: UInt64 = 0
    private var readiness: [UUID: ComposerReadiness] = [:]

    init(
        directory: URL,
        clock: WatchClock?,
        onChange: @escaping ([UUID: ComposerReadiness]) -> Void
    ) {
        self.url = directory.appendingPathComponent("events.ndjson")
        self.clock = clock
        self.onChange = onChange
    }

    func start() {
        clock?.add(self) { [weak self] in self?.drain() }
    }

    func stop() {
        clock?.remove(self)
    }

    /// Reads everything appended since the last call. Synchronous, so tests need no
    /// expectations — the seam `TranscriptWatcher.drain()` establishes.
    ///
    /// Always passes `hasChosenStart: true`, unlike `TranscriptWatcher`. That watcher
    /// deliberately skips whatever is already in a per-session transcript on its first
    /// look, because a restored session's history is not news. This log is the opposite:
    /// it is the only record of which sessions are currently live, and this is the one
    /// app-wide watcher, started once, against a file other processes are free to have
    /// written to first. Passing `false` here would make `TailReader` treat that
    /// pre-existing content as history and jump straight to EOF — every already-running
    /// session would read as `.unknown` until its next hook fired.
    func drain() {
        let tail = TailReader.read(
            url: url, offset: offset, hasChosenStart: true, truncation: .resumeAtEnd
        )
        offset = tail.offset

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
