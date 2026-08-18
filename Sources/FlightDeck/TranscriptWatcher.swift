import Foundation

/// Tails one session's Claude transcript and reports the newest `customTitle`.
///
/// `claude` creates the transcript slightly after launch, so the watcher polls for the
/// file and only then starts reading. Reads are incremental: only bytes appended since
/// the last read are parsed. A missing file is not an error — it just means `claude`
/// isn't running, and the sidebar name stays a local label.
///
/// **Threading.** The read and the JSON parse are the expensive half and do not touch
/// actor state, so `poll()` runs them off the main actor and hops back only to apply the
/// result. That split matters because transcript lines are large — one assistant record
/// carries entire tool inputs and results — and the parse used to land on the main thread
/// at exactly the moment an agent was streaming output. `drain()` keeps the whole thing
/// synchronous for tests.
///
/// **Scheduling.** This type owns no timer. `SessionStore` drives every watcher from a
/// single `WatchClock`, so N tabs cost one wakeup rather than N — see that type.
@MainActor
final class TranscriptWatcher {
    private let sessionID: UUID
    /// Readable so `SessionStore` can expose which transcript a tab is actually tailing
    /// (`watchedTranscriptURL(of:)`); immutable, so a watcher is replaced rather than
    /// re-pointed when the tab's conversation or transcript directory changes. Those are
    /// the only two things that move a transcript: the project a tab is filed under does
    /// not feed this path at all, and `SessionStore.moveSession` deliberately leaves
    /// watchers alone.
    let url: URL
    private let onTitle: (String) -> Void
    private let onSubagentCount: (Int) -> Void

    /// Outstanding top-level `Agent` tool_use ids. Cleared at every turn boundary, which
    /// is what makes a miscount from attaching mid-turn self-correcting rather than
    /// permanent.
    private var outstandingAgents: Set<String> = []

    private var offset: UInt64 = 0
    /// Whether the position to start reading from has been decided yet. See `Scan.read`.
    private var hasChosenStart = false

    /// The clock this watcher is registered with, if any. Nil in tests, which call
    /// `drain()` directly.
    private weak var clock: WatchClock?
    private var isPolling = false

    /// `onSubagentCount` defaults to a no-op so title-only call sites are unaffected.
    init(
        sessionID: UUID,
        url: URL,
        clock: WatchClock? = nil,
        onTitle: @escaping (String) -> Void,
        onSubagentCount: @escaping (Int) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.url = url
        self.clock = clock
        self.onTitle = onTitle
        self.onSubagentCount = onSubagentCount
    }

    func start() {
        clock?.add(self) { [weak self] in self?.poll() }
    }

    func stop() {
        clock?.remove(self)
    }

    /// One scheduled pass: reads and parses off the main actor, applies on it.
    ///
    /// Re-entrancy is guarded rather than queued. A pass that outlives its tick means the
    /// file is big enough that the *next* tick has nothing useful to add — it would read
    /// from a stale offset — so dropping it is both cheaper and more correct than letting
    /// two passes interleave over one `offset`.
    private func poll() {
        guard !isPolling else { return }
        isPolling = true

        let url = self.url
        let sessionID = self.sessionID
        let offset = self.offset
        let hasChosenStart = self.hasChosenStart

        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                Scan.read(
                    url: url,
                    offset: offset,
                    hasChosenStart: hasChosenStart,
                    sessionID: sessionID
                )
            }.value

            guard let self else { return }
            self.apply(scan)
            self.isPolling = false
        }
    }

    /// Reads everything appended since the last call and reports the last title found.
    /// Synchronous so tests need no expectations.
    func drain() {
        apply(
            Scan.read(
                url: url,
                offset: offset,
                hasChosenStart: hasChosenStart,
                sessionID: sessionID
            )
        )
    }

    /// Folds a scan's events into the watcher's state and fires the callbacks.
    /// Everything here is cheap and main-actor-bound; the expensive half is `Scan.read`.
    private func apply(_ scan: Scan) {
        hasChosenStart = scan.hasChosenStart
        offset = scan.offset

        var lastTitle: String?
        var countChanged = false

        for event in scan.events {
            switch event {
            case .title(let title):
                lastTitle = title
            case .agentStarted(let id):
                if outstandingAgents.insert(id).inserted { countChanged = true }
            case .agentFinished(let id):
                if outstandingAgents.remove(id) != nil { countChanged = true }
            case .turnEnded:
                if !outstandingAgents.isEmpty {
                    outstandingAgents.removeAll()
                    countChanged = true
                }
            }
        }

        if let lastTitle { onTitle(lastTitle) }
        if countChanged { onSubagentCount(outstandingAgents.count) }
    }
}

/// The result of one look at a transcript: how far reading got, and what it found.
///
/// Deliberately pure and `Sendable` — no actor state, no callbacks — so the read and the
/// JSON parse can run off the main actor and only the fold back into watcher state has to
/// return to it.
struct Scan: Sendable {
    var offset: UInt64
    var hasChosenStart: Bool
    var events: [ClaudeSession.TranscriptEvent] = []

    /// Reads and parses everything appended after `offset`.
    ///
    /// Returns the caller's own position unchanged when there is nothing to do (no new
    /// bytes, no complete line), which makes "no change" a cheap no-op rather than a
    /// special case at the call site.
    static func read(
        url: URL,
        offset: UInt64,
        hasChosenStart: Bool,
        sessionID: UUID
    ) -> Scan {
        var result = Scan(offset: offset, hasChosenStart: hasChosenStart)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Nothing on disk, but that settles where reading will start: a transcript that
            // does not exist while we are *already* watching has no history to skip, so
            // whatever `claude` creates here later is ours from byte 0.
            //
            // Deciding it here rather than on the first successful open is what makes the
            // first `/rename` of a session arrive. `claude` buffers its startup records and
            // does not create the transcript until it first has something to persist —
            // for a session renamed before its first turn, that is the rename itself. The
            // file therefore does not appear empty and then grow: it springs into existence
            // with the `custom-title` record already inside, and the branch below would
            // seek straight past it. Every later rename appended to a file we are by then
            // tracking, which is why only the first one went missing.
            result.hasChosenStart = true
            return result
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0

        // The file already existed on our first look, so it predates the watcher: start
        // tailing from its current end rather than from 0. A restored session points at a
        // transcript that may be huge (a whole prior conversation); without this, the first
        // read would replay every old `custom-title` record — most recently clobbering a
        // rename made while `claude` wasn't running — and would parse the entire file.
        if !result.hasChosenStart {
            result.hasChosenStart = true
            result.offset = size
        } else if size < result.offset {
            // A shorter file means it was replaced; start over. This only detects a
            // *smaller* replacement — a same-or-larger replacement at the same path would
            // be treated as a continuation. That's acceptable here because the URL is
            // keyed to one session UUID for the watcher's whole lifetime.
            result.offset = 0
        }
        guard size > result.offset else { return result }

        try? handle.seek(toOffset: result.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return result }

        // Consume only through the last complete line. A trailing partial line is left
        // unread so the next read sees it whole — `claude` appends this file while we
        // read it, and a read can land mid-write.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return result }
        let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
        result.offset += UInt64(consumed)

        for raw in String(decoding: data[..<lastNewline], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            result.events += ClaudeSession.events(inLine: String(raw), sessionID: sessionID)
        }

        return result
    }
}
