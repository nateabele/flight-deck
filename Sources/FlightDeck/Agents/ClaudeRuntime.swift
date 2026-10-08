import Foundation
import IntakeKit

/// Claude's runtime: one `TranscriptWatcher` per attached tab (the transcript is per
/// conversation) plus the single shared `SessionStatusWatcher` (the registry is not).
@MainActor
final class ClaudeRuntime: AgentRuntime {
    /// One conversation's event source: the single watcher, plus everyone listening to it.
    private struct Source {
        let subscribers: SubscriberList
        let watcher: TranscriptWatcher?
        /// Rebuilt from `subagents/` files, so it sees agents launched before this attach.
        let subagents: SubagentWatcher?
        /// The transcript fold's count: it sees a launch the instant it is written, before the
        /// agent's own file exists.
        var foldCount = 0
    }

    private var sources: [UUID: Source] = [:]
    private let clock: WatchClock?
    /// Where a conversation's text goes for ⌘K search. A closure rather than a stored
    /// reference, and re-read on every message batch rather than once at `attach` time: the
    /// index does not exist yet for the first few seconds of a real launch — `AppDelegate`
    /// wires it in after this runtime may already have been built and started watching — and
    /// nil in every test, where nothing ever wires it in at all.
    private let searchIndex: () -> SearchIndex?
    /// Which project a conversation currently belongs to, for the same `ingest(_:for:offset:)`
    /// call. Looked up live rather than captured at `attach` time so a tab moved to another
    /// project mid-life (`SessionStore.moveSession`) keeps crediting the project it actually
    /// belongs to now, not the one it was filed under when its watcher started.
    private let projectPath: (UUID) -> String?
    /// Where a conversation's agent is working right now, for the same `ingest` call — the
    /// literal directory, which follows the tab into a worktree while `projectPath` stays put.
    /// A sibling closure rather than a stored value for the same reason as `projectPath`: a
    /// tab that follows its agent into a worktree mid-life must credit the worktree it is in
    /// now, not the directory its watcher happened to start in.
    private let workingDirectory: (UUID) -> String?
    /// When this conversation's agent process started, keyed by conversation id. Subagent files
    /// older than it belong to a previous run of the conversation and are not this run's agents.
    private let agentStartedAt: (UUID) -> Date?
    /// When the user last submitted a prompt in this conversation: finished agents older than
    /// it are dropped from the tree.
    private let lastPromptSubmit: (UUID) -> Date?

    init(
        clock: WatchClock? = nil,
        searchIndex: @escaping () -> SearchIndex? = { nil },
        projectPath: @escaping (UUID) -> String? = { _ in nil },
        workingDirectory: @escaping (UUID) -> String? = { _ in nil },
        agentStartedAt: @escaping (UUID) -> Date? = { _ in nil },
        lastPromptSubmit: @escaping (UUID) -> Date? = { _ in nil }
    ) {
        self.clock = clock
        self.searchIndex = searchIndex
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory
        self.agentStartedAt = agentStartedAt
        self.lastPromptSubmit = lastPromptSubmit
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
        var subagents: SubagentWatcher?
        if let url = binding.transcriptURL {
            let directory = url.deletingPathExtension()
                .appendingPathComponent("subagents", isDirectory: true)
            subagents = SubagentWatcher(
                directory: directory, clock: clock,
                startedAt: { [weak self] in self?.agentStartedAt(id) },
                keepDoneSince: { [weak self] in self?.lastPromptSubmit(id) ?? self?.agentStartedAt(id) },
                onChange: { [weak self] tree in self?.publish(tree, for: id) }
            )
            watcher = TranscriptWatcher(
                sessionID: id,
                url: url,
                clock: clock,
                onTitle: { subscribers.emit(.title($0)) },
                onSubagentCount: { [weak self] in self?.fold($0, for: id) },
                onAPIError: { subscribers.emit(.apiError($0)) },
                onSignals: { subscribers.emit(.outputSignals($0)) },
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
                    guard let self, let index = self.searchIndex(),
                          let path = self.projectPath(id),
                          let workingDirectory = self.workingDirectory(id)
                    else { return }
                    let ref = TranscriptRef(
                        url: url, projectPath: path, accountHome: AgentID.claude.builtInHome,
                        workingDirectory: workingDirectory, conversationID: id.uuidString.lowercased(),
                        agent: .claude, provenance: nil, indexedName: nil, modified: Date()
                    )
                    // `offset: nil` — see `SearchIndex.ingest`'s doc comment. This watcher
                    // starts at end-of-file (it exists to catch titles, not backlog), so its
                    // own read position is never the right number to record as indexing
                    // progress: doing so would make the backfill resume from there and
                    // silently never index this conversation's history.
                    try? index.ingest(messages, for: ref, offset: nil)
                }
            )
            watcher?.start()
        }
        sources[id] = Source(subscribers: subscribers, watcher: watcher, subagents: subagents)
        subagents?.start()
        subagents?.rescan()
        return token
    }

    /// The count is the larger of the transcript fold and the tree. The fold sees a launch
    /// the instant it is written, before the agent's own file exists; the tree sees agents
    /// launched before this attach, which the fold (it starts at end of file) never will.
    private func fold(_ count: Int, for id: UUID) {
        sources[id]?.foldCount = count
        sources[id]?.subagents?.rescan()
        emitCount(for: id)
    }

    private func publish(_ tree: SubagentTree, for id: UUID) {
        sources[id]?.subscribers.emit(.subagents(tree))
        emitCount(for: id)
    }

    private func emitCount(for id: UUID) {
        guard let source = sources[id] else { return }
        let count = max(source.foldCount, source.subagents?.tree.liveTopLevelCount ?? 0)
        source.subscribers.emit(.subagentCount(count))
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
        source.subagents?.stop()
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

    /// Fan-out point for the shared hook-event watcher, mirroring `ingest(_ entries:)` for
    /// the status registry. `SessionStore` owns the one watcher; this maps its per-session
    /// report onto the tabs subscribed to that conversation.
    func ingest(readiness: [UUID: ComposerReadiness]) {
        for (sessionID, value) in readiness {
            sources[sessionID]?.subscribers.emit(.lifecycle(value))
        }
    }

    /// Test seam mirroring `TranscriptWatcher.drain()`, so runtime tests need no clock.
    func drainForTesting() {
        for source in sources.values {
            source.watcher?.drain()
            source.subagents?.rescan()
        }
    }
}
