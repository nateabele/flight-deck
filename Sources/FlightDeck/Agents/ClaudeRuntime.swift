import Foundation

/// Claude's runtime: one `TranscriptWatcher` per attached tab (the transcript is per
/// conversation) plus the single shared `SessionStatusWatcher` (the registry is not).
@MainActor
final class ClaudeRuntime: AgentRuntime {
    /// One conversation's event source: the single watcher, plus everyone listening to it.
    private struct Source {
        let subscribers: SubscriberList
        let watcher: TranscriptWatcher?
    }

    private var sources: [UUID: Source] = [:]
    private let clock: WatchClock?
    /// Where a conversation's text goes for ⌘K search. A closure rather than a stored
    /// reference, and re-read on every message batch rather than once at `attach` time: the
    /// index does not exist yet for the first few seconds of a real launch — `AppDelegate`
    /// wires it in after this runtime may already have been built and started watching — and
    /// nil in every test, where nothing ever wires it in at all.
    private let searchIndex: () -> SearchIndex?
    /// Which project a conversation currently belongs to, for the same `ingest(_:from:
    /// projectPath:offset:)` call. Looked up live rather than captured at `attach` time so a
    /// tab moved to another project mid-life (`SessionStore.moveSession`) keeps crediting the
    /// project it actually belongs to now, not the one it was filed under when its watcher
    /// started.
    private let projectPath: (UUID) -> String?

    init(
        clock: WatchClock? = nil,
        searchIndex: @escaping () -> SearchIndex? = { nil },
        projectPath: @escaping (UUID) -> String? = { _ in nil }
    ) {
        self.clock = clock
        self.searchIndex = searchIndex
        self.projectPath = projectPath
    }

    /// Subscribes `tab` to `binding`'s conversation, starting a watcher if this is the first
    /// subscriber. A second tab on the same conversation joins the existing source rather
    /// than replacing it — which is what the old `attachments[id] = …` did, stopping the
    /// first tab's watcher and leaving the store to compensate with a value-matched fan-out.
    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken {
        let id = binding.conversationID
        let token = AttachmentToken(conversationID: id, tab: tab)

        if let existing = sources[id] {
            // `binding.transcriptURL` is discarded here — the joining subscriber gets the
            // first attacher's watcher, not its own. If two tabs land on one conversation
            // with different transcript directories, both end up tailing the first attacher's
            // file, and a later `retarget` of the second tab (SessionStore.retarget) cannot
            // repoint it while the first tab stays attached. Tracked follow-up, not fixed here.
            existing.subscribers.add(token, onEvent)
            return token
        }

        let subscribers = SubscriberList()
        subscribers.add(token, onEvent)

        var watcher: TranscriptWatcher?
        if let url = binding.transcriptURL {
            watcher = TranscriptWatcher(
                sessionID: id,
                url: url,
                clock: clock,
                onTitle: { subscribers.emit(.title($0)) },
                onSubagentCount: { subscribers.emit(.subagentCount($0)) },
                // `onMessages` is passed unconditionally, never `nil` — so `wantsMessages` (see
                // `Scan.read`'s doc comment, which the gate was written to serve) is
                // permanently true for every Claude session, including in tests and for a
                // launch whose `SQLiteSearchIndex.init` failed and will never have an index.
                // Deciding at attach time whether to omit this closure would need to know now
                // whether `searchIndex()` will EVER return non-nil, which it cannot: nil here
                // means "not wired up yet" far more often than "never will be" (see the
                // property comment above), and gating on today's answer would reintroduce the
                // exact ordering dependency that reading it live was meant to avoid — a
                // session attached before `AppDelegate.startSearch` runs would silently never
                // become searchable, forever, not just late.
                //
                // The cost of leaving it open is bounded, though: `TranscriptWatcher` decodes
                // every line's JSON regardless (for titles and subagent counts), so
                // `TranscriptExtractor.messages(inObject:)` never re-parses — it only does a
                // few dictionary lookups, a timestamp format, and a trim per line, then the
                // closure's own guard drops the result for free when `searchIndex()` is nil.
                // Not the "six hundred lines of tokenizer" cost this feature exists to avoid
                // elsewhere.
                onMessages: { [weak self] messages in
                    guard let self, let index = self.searchIndex(), let path = self.projectPath(id)
                    else { return }
                    // `offset: nil` — see `SearchIndex.ingest`'s doc comment. This watcher
                    // starts at end-of-file (it exists to catch titles, not backlog), so its
                    // own read position is never the right number to record as indexing
                    // progress: doing so would make the backfill resume from there and
                    // silently never index this conversation's history.
                    try? index.ingest(messages, from: url, projectPath: path, offset: nil)
                }
            )
            watcher?.start()
        }
        sources[id] = Source(subscribers: subscribers, watcher: watcher)
        return token
    }

    /// Drops one subscriber, and the watcher only when it was the last.
    ///
    /// Stopped explicitly rather than left to the released `Source`: it survives its owner by
    /// its registration on the shared `WatchClock`, and although that registration is weak
    /// and self-prunes, an invariant that holds only because of a retention detail two files
    /// away is not one to lean on.
    func detach(_ token: AttachmentToken) {
        guard let source = sources[token.conversationID] else { return }
        source.subscribers.remove(token)
        guard source.subscribers.isEmpty else { return }
        source.watcher?.stop()
        sources[token.conversationID] = nil
    }

    /// Fan-out point for the shared status watcher. `SessionStore` owns the one
    /// `SessionStatusWatcher` and hands its output here rather than this type owning a
    /// second one — the registry must be scanned once per tick, not once per tab.
    func ingest(_ entries: [pid_t: ClaudeStatusFile.Entry]) {
        for entry in entries.values {
            sources[entry.sessionID]?.subscribers.emit(.activity(entry.activity))
        }
    }

    /// Test seam mirroring `TranscriptWatcher.drain()`, so runtime tests need no clock.
    func drainForTesting() {
        for source in sources.values { source.watcher?.drain() }
    }
}
