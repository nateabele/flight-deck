import Foundation
import IntakeKit

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

    /// The thread id, for `IndexedMessage.conversationID` — codex's own session id, not
    /// derived from anything in the rollout the watcher reads. Threaded straight through
    /// rather than parsed back out of `session_meta`, the way `TranscriptWatcher` is handed
    /// `sessionID` rather than deriving it from the transcript it tails.
    private let conversationID: UUID
    private let onEvent: (AgentEvent) -> Void
    /// Reports conversation text to the search index. A genuine optional, not a defaulted
    /// no-op — mirrors `TranscriptWatcher.onMessages`: `apply` checks it before paying for
    /// `CodexSearchCorpus.indexedMessages(inObject:)` at all, so a watcher built without one
    /// truly does no extra work rather than building an array nobody reads.
    private let onMessages: (([IndexedMessage]) -> Void)?
    private var offset: UInt64 = 0
    /// Whether the position to start reading from has been decided yet. See `TailReader`.
    private var hasChosenStart = false
    private weak var clock: WatchClock?
    private var isPolling = false

    init(
        url: URL, conversationID: UUID, clock: WatchClock? = nil,
        onEvent: @escaping (AgentEvent) -> Void,
        onMessages: (([IndexedMessage]) -> Void)? = nil
    ) {
        self.url = url
        self.conversationID = conversationID
        self.clock = clock
        self.onEvent = onEvent
        self.onMessages = onMessages
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
        let conversationID = self.conversationID
        let wantsMessages = onMessages != nil

        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                CodexScan.read(
                    url: url, offset: offset, hasChosenStart: hasChosenStart,
                    conversationID: conversationID, wantsMessages: wantsMessages
                )
            }.value

            guard let self else { return }
            self.apply(scan)
            self.isPolling = false
        }
    }

    /// Synchronous pass, so tests need no expectations. Mirrors `TranscriptWatcher.drain()`.
    func drain() {
        apply(CodexScan.read(
            url: url, offset: offset, hasChosenStart: hasChosenStart,
            conversationID: conversationID, wantsMessages: onMessages != nil
        ))
    }

    /// Folds a scan's events into the watcher's state and fires the callbacks. Cheap and
    /// main-actor-bound; the expensive half is `CodexScan.read`.
    private func apply(_ scan: CodexScan) {
        hasChosenStart = scan.hasChosenStart
        offset = scan.offset

        // Any appended line at all — regardless of whether `CodexEventMapper` recognises it —
        // is positive evidence codex's TUI is up and writing to this file: the codex analogue
        // of claude's `SessionStart` hook, which is why this stands apart from the per-line
        // fold below rather than living inside it. `CodexEventMapper` decides which lines are
        // turn boundaries; this decides only whether the process is alive, and a line it does
        // not recognise still proves that.
        //
        // Gated on `scan.sawLines` being genuinely true, never on merely being called: a
        // poll of a file that already existed before this watcher started reads no lines on
        // its first pass (`TailReader` seeks straight to EOF), so a tab attached to a thread
        // whose codex process has not booted yet stays `.unknown` — exactly the boot window
        // the legacy screen gate exists to cover, and the same stale-`.live` hazard already
        // fixed once for claude's watcher.
        //
        // The other ordering — no file on disk yet at attach, which is the routine case:
        // `CodexAdapter.prepare` hands this watcher a computed path before codex's TUI has
        // necessarily written anything there — reads no lines on that same first pass either
        // (`TailReader`'s "file missing" branch only marks a start chosen, at offset 0; see
        // its own "deliberately not symmetric" comment), so the gate stays closed there too.
        // Once the file appears, the FIRST poll to see it reads from byte 0 rather than
        // fast-forwarding, so that file's opening content — not just what arrives after — is
        // what correctly fires `.live`.
        if scan.sawLines {
            onEvent(.lifecycle(.live))
        }

        // Emitted in file order and not folded: unlike claude's sub-agent counting, nothing
        // here needs remembering — a turn boundary is complete in one record.
        for event in scan.events { onEvent(event) }
        if !scan.messages.isEmpty { onMessages?(scan.messages) }
    }
}

/// The result of one look at a rollout: how far reading got, the turn-boundary events found,
/// and any conversation text for the search index.
///
/// Pure and `Sendable` — no actor state, no callbacks — mirroring `Scan`, for the same
/// reason: the file read and the JSON parse are the expensive half, so keeping this free of
/// actor state is what lets `poll()` run them off the main actor and hop back only for the
/// lightweight fold in `apply`.
struct CodexScan: Sendable {
    var offset: UInt64
    var hasChosenStart: Bool
    var events: [AgentEvent] = []
    /// Conversation text found in this pass, for the search index.
    ///
    /// Collected here rather than in a second reader for the same reason `Scan.messages` is:
    /// this pass already paid for the file read and the JSON parse, and rollout lines large
    /// enough to carry a whole turn's prose make doing either twice the most expensive thing
    /// in the app.
    var messages: [IndexedMessage] = []

    /// Whether this pass read any complete line at all, recognised or not.
    ///
    /// Distinct from `!events.isEmpty` on purpose, and the distinction is the whole point: a
    /// rollout line `CodexEventMapper` does not map is still proof that codex's TUI is up and
    /// writing, which is what `CodexRolloutWatcher.apply` turns into `.lifecycle(.live)` — the
    /// codex analogue of claude's `SessionStart` hook. Folding this into `events` would make
    /// liveness depend on the mapper's vocabulary, so a release that renamed a record type
    /// would silently stop reporting a live agent rather than merely stop reporting a turn.
    var sawLines = false

    /// `wantsMessages` gates `CodexSearchCorpus.indexedMessages(inObject:)`, not just whether
    /// `messages` ends up read — without the gate a watcher with no `onMessages` subscriber
    /// would still pay for extraction on every line, for nothing. Each line is JSON-decoded
    /// exactly once regardless — `CodexEventMapper.events(inRecord:)` and
    /// `CodexSearchCorpus.indexedMessages(inObject:)` both take the same already-parsed
    /// record, rather than each re-parsing the line themselves.
    static func read(
        url: URL, offset: UInt64, hasChosenStart: Bool, conversationID: UUID, wantsMessages: Bool
    ) -> CodexScan {
        let tail = TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart)
        var result = CodexScan(offset: tail.offset, hasChosenStart: tail.hasChosenStart)
        // Recorded from the tail rather than from `result.events` below — see `sawLines`.
        result.sawLines = !tail.lines.isEmpty
        // `tail.lineOffsets` is `TailReader`'s own accounting of where each line starts, in
        // lockstep with `tail.lines` — not reconstructed here by summing line lengths, which
        // would silently drift the moment a blank line in the tailed range is consumed but
        // (like `tail.lines`) never appears in either array.
        for (line, lineOffset) in zip(tail.lines, tail.lineOffsets) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            result.events += CodexEventMapper.events(inRecord: record)
            let signals = AgentOutputScan.signals(line: line, record: record)
            if !signals.isEmpty { result.events.append(.outputSignals(signals)) }
            if wantsMessages {
                result.messages += CodexSearchCorpus.indexedMessages(
                    inObject: record, conversationID: conversationID.uuidString.lowercased(),
                    at: Int(lineOffset)
                )
            }
        }
        return result
    }
}
