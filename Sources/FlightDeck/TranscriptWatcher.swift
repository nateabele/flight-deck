import Foundation

/// Tails one session's Claude transcript and reports the newest `customTitle`.
///
/// `claude` creates the transcript slightly after launch, so the watcher polls for the
/// file and only then starts reading. Reads are incremental: only bytes appended since
/// the last read are parsed. A missing file is not an error — it just means `claude`
/// isn't running, and the sidebar name stays a local label.
@MainActor
final class TranscriptWatcher {
    private let sessionID: UUID
    /// Readable so `SessionStore` can expose which transcript a tab is actually tailing
    /// (`watchedTranscriptURL(of:)`); immutable, so a watcher is replaced rather than
    /// re-pointed when the tab's conversation or project changes.
    let url: URL
    private let onTitle: (String) -> Void
    private let onSubagentCount: (Int) -> Void

    /// Outstanding top-level `Agent` tool_use ids. Cleared at every turn boundary, which
    /// is what makes a miscount from attaching mid-turn self-correcting rather than
    /// permanent.
    private var outstandingAgents: Set<String> = []

    private var offset: UInt64 = 0
    /// Whether `offset` has been seeded to the file's size yet. See `drain()`.
    private var hasSeekedToEnd = false
    private var timer: DispatchSourceTimer?

    /// `onSubagentCount` defaults to a no-op so title-only call sites are unaffected.
    init(
        sessionID: UUID,
        url: URL,
        onTitle: @escaping (String) -> Void,
        onSubagentCount: @escaping (Int) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.url = url
        self.onTitle = onTitle
        self.onSubagentCount = onSubagentCount
    }

    deinit { timer?.cancel() }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.drain() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reads everything appended since the last call and reports the last title found.
    /// Synchronous so tests need no expectations.
    func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0

        // On the first time we ever manage to open the file, start tailing from its
        // current end rather than from 0. A restored session points at a transcript
        // that already exists and may be huge (a whole prior conversation); without
        // this, the first drain would replay every old `custom-title` record — most
        // recently clobbering a rename made while `claude` wasn't running — and would
        // parse the entire file on the main thread. A brand-new session's file doesn't
        // exist yet at this point, so seeding to its (empty) size here is a no-op and
        // every subsequent drain still sees only genuinely new bytes.
        if !hasSeekedToEnd {
            hasSeekedToEnd = true
            offset = size
        } else if size < offset {
            // A shorter file means it was replaced; start over. This only detects a
            // *smaller* replacement — a same-or-larger replacement at the same path would
            // be treated as a continuation. That's acceptable here because the URL is
            // keyed to one session UUID for the watcher's whole lifetime.
            offset = 0
        }
        guard size > offset else { return }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Consume only through the last complete line. A trailing partial line is left
        // unread so the next drain sees it whole — `claude` appends this file while we
        // read it, and a drain can land mid-write.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
        offset += UInt64(consumed)

        var lastTitle: String?
        var countChanged = false

        for raw in String(decoding: data[..<lastNewline], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            for event in ClaudeSession.events(inLine: String(raw), sessionID: sessionID) {
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
        }

        if let lastTitle { onTitle(lastTitle) }
        if countChanged { onSubagentCount(outstandingAgents.count) }
    }
}
