import Foundation

/// Tails one codex thread's rollout `.jsonl` and reports turn boundaries.
///
/// Codex's own app-server cannot tell us this: its notifications go only to the connection
/// that made the change, and Flight Deck's turns run in a `codex resume` TUI — a different
/// process, therefore a different connection. The rollout is written by whoever drives the
/// turn, so it is the one source that does not care who that is.
///
/// **Threading.** Mirrors `TranscriptWatcher`: the read and parse run off the main actor,
/// and only the fold hops back. **Scheduling.** Owns no timer; `SessionStore`'s single
/// `WatchClock` drives every watcher, so N tabs cost one wakeup.
@MainActor
final class CodexRolloutWatcher {
    /// Readable so a runtime can say which rollout a tab is actually tailing; immutable, so
    /// a watcher is replaced rather than re-pointed when a tab's thread changes.
    let url: URL

    private let onEvent: (AgentEvent) -> Void
    private var offset: UInt64 = 0
    /// Whether the position to start reading from has been decided yet. See `TailReader`.
    private var hasChosenStart = false
    private weak var clock: WatchClock?
    private var isPolling = false

    init(url: URL, clock: WatchClock? = nil, onEvent: @escaping (AgentEvent) -> Void) {
        self.url = url
        self.clock = clock
        self.onEvent = onEvent
    }

    func start() {
        clock?.add(self) { [weak self] in self?.poll() }
    }

    func stop() {
        clock?.remove(self)
    }

    /// One scheduled pass. Re-entrancy is guarded rather than queued: a pass that outlives
    /// its tick means the next tick would read from a stale offset, so dropping it is both
    /// cheaper and more correct than letting two passes interleave.
    private func poll() {
        guard !isPolling else { return }
        isPolling = true

        let url = self.url
        let offset = self.offset
        let hasChosenStart = self.hasChosenStart

        Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart)
            }.value

            guard let self else { return }
            self.apply(read)
            self.isPolling = false
        }
    }

    /// Synchronous pass, so tests need no expectations. Mirrors `TranscriptWatcher.drain()`.
    func drain() {
        apply(TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart))
    }

    private func apply(_ read: TailRead) {
        hasChosenStart = read.hasChosenStart
        offset = read.offset
        // Emitted in file order and not folded: unlike claude's sub-agent counting, nothing
        // here needs remembering — a turn boundary is complete in one record.
        for line in read.lines {
            for event in CodexEventMapper.events(inRolloutLine: line) { onEvent(event) }
        }
    }
}
