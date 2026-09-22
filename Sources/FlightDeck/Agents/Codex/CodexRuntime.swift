import Foundation

/// Codex's observation half: everything is read from the files codex writes.
///
/// It does not use the app-server at all, and that is the whole point. Codex's notifications
/// are scoped to the connection that made the change, and Flight Deck runs turns in a
/// `codex resume` TUI — a different process, so a different connection. The app-server that
/// created a thread is never told what the user does in it. Files have no such rule.
///
/// The shape mirrors `ClaudeRuntime`: one watcher per tab over a per-conversation file, plus
/// one shared watcher — one per codex account, not one for the whole app — over that
/// account's `session_index.jsonl`, fanned out by conversation id.
@MainActor
final class CodexRuntime: AgentRuntime {
    private struct Source {
        let subscribers: SubscriberList
        let watcher: CodexRolloutWatcher?
    }

    private var sources: [UUID: Source] = [:]
    private let clock: WatchClock?
    private let indexURL: URL
    /// Where a conversation's text goes for ⌘K search. A closure rather than a stored
    /// reference, and re-read on every message batch rather than once at `attach` time —
    /// same reasoning as `ClaudeRuntime`'s own property: the index does not exist yet for the
    /// first few seconds of a real launch, and is nil in every test, where nothing ever wires
    /// it in at all.
    private let searchIndex: () -> SearchIndex?
    /// Which project a thread currently belongs to, for the same `ingest(_:for:offset:)`
    /// call. Looked up live rather than captured at `attach` time so a tab moved to another
    /// project mid-life keeps crediting the project it actually belongs to now.
    private let projectPath: (UUID) -> String?
    /// Where a thread's agent is working right now, for the same `ingest` call — the literal
    /// directory, which follows the tab into a worktree while `projectPath` stays put. A
    /// sibling closure rather than a stored value for the same reason as `projectPath`.
    private let workingDirectory: (UUID) -> String?

    /// Built on first attach and dropped with the last one, so a user with no codex tabs
    /// never has a watcher ticking over codex's index.
    private var names: CodexNameWatcher?

    init(
        clock: WatchClock? = nil, indexURL: URL = CodexNameWatcher.defaultIndexURL,
        searchIndex: @escaping () -> SearchIndex? = { nil },
        projectPath: @escaping (UUID) -> String? = { _ in nil },
        workingDirectory: @escaping (UUID) -> String? = { _ in nil }
    ) {
        self.clock = clock
        self.indexURL = indexURL
        self.searchIndex = searchIndex
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory
    }

    /// Subscribes `tab` to `binding`'s thread, starting a watcher if this is the first
    /// subscriber. A second tab on the same thread joins the existing source rather than
    /// replacing it — which is what the old `attachments[id] = …` did, stopping the first
    /// tab's watcher and leaving the store to compensate with a value-matched fan-out.
    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken {
        let id = binding.conversationID
        let token = AttachmentToken(conversationID: id, tab: tab)

        if let existing = sources[id] {
            // `binding.transcriptURL` is discarded here — the joining subscriber gets the
            // first attacher's watcher, not its own. If two tabs land on one thread with
            // different transcript directories, both end up tailing the first attacher's
            // file, and a later `retarget` of the second tab (SessionStore.retarget) cannot
            // repoint it while the first tab stays attached. Tracked follow-up, not fixed here.
            existing.subscribers.add(token, onEvent)
            return token
        }

        let subscribers = SubscriberList()
        subscribers.add(token, onEvent)

        var watcher: CodexRolloutWatcher?
        if let url = binding.transcriptURL {
            watcher = CodexRolloutWatcher(
                url: url, conversationID: id, clock: clock,
                onEvent: { subscribers.emit($0) },
                // `onMessages` is passed unconditionally, never `nil` — see `ClaudeRuntime
                // .attach`'s own comment on this exact point. Deciding at attach time whether
                // to omit this closure would need to know now whether `searchIndex()` will
                // EVER return non-nil, which it cannot, and gating on today's answer would
                // reintroduce the ordering dependency reading it live was meant to avoid: a
                // thread attached before `AppDelegate.startSearch` runs would silently never
                // become searchable, forever, not just late. The cost of leaving it open is
                // bounded the same way, too — `CodexScan.read` decodes every line's JSON
                // regardless (for turn boundaries), so `CodexSearchCorpus
                // .indexedMessages(inObject:)` never re-parses.
                onMessages: { [weak self] messages in
                    guard let self, let index = self.searchIndex(),
                          let path = self.projectPath(id),
                          let workingDirectory = self.workingDirectory(id)
                    else { return }
                    let ref = TranscriptRef(
                        url: url, projectPath: path, accountHome: AgentID.codex.builtInHome,
                        workingDirectory: workingDirectory, conversationID: id.uuidString.lowercased(),
                        agent: .codex,
                        // `nil`, not a guess. A Flight-Deck-driven thread runs in a real
                        // `codex resume` TUI, not `codex exec` — the one value `provenance`
                        // exists to flag (see `SearchRanker`'s `.automated` tier) — but this
                        // runtime never reads the rollout's `session_meta.payload.source`
                        // itself, so claiming any specific string here would be a guess, not
                        // an observation. `nil` is the honest answer, and it is also the
                        // correct one: `SearchRanker` treats nil as `.transcript`, not
                        // `.automated`, so the conversation the user is having right now
                        // ranks above a `codex exec` run instead of below it.
                        provenance: nil, indexedName: nil, modified: Date()
                    )
                    // `offset: nil` — see `SearchIndex.ingest`'s doc comment. This watcher
                    // starts at end-of-file (it exists to catch turn boundaries, not
                    // backlog), so its own read position is never the right number to record
                    // as indexing progress: doing so would make the backfill resume from
                    // there and silently never index this thread's history.
                    try? index.ingest(messages, for: ref, offset: nil)
                }
            )
            watcher?.start()
        }
        sources[id] = Source(subscribers: subscribers, watcher: watcher)

        // Registered once per thread, not once per tab: a tab still has a name even with no
        // rollout to tail, and the list below is what fans that name out to every subscriber.
        nameWatcher().register(id) { subscribers.emit(.title($0)) }
        return token
    }

    /// Drops one subscriber, and the watcher — plus the shared name watcher's registration —
    /// only when it was the last.
    ///
    /// Stopped explicitly rather than left to the released `Source`: it survives its owner by
    /// its registration on the shared `WatchClock`, and although that registration is weak
    /// and self-prunes, an invariant that holds only because of a retention detail two files
    /// away is not one to lean on.
    func detach(_ token: AttachmentToken) {
        let id = token.conversationID
        guard let source = sources[id] else { return }
        source.subscribers.remove(token)
        guard source.subscribers.isEmpty else { return }

        source.watcher?.stop()
        sources[id] = nil
        names?.unregister(id)
        if names?.isEmpty == true {
            names?.stop()
            names = nil
        }
    }

    private func nameWatcher() -> CodexNameWatcher {
        if let names { return names }
        let watcher = CodexNameWatcher(url: indexURL, clock: clock)
        watcher.start()
        names = watcher
        return watcher
    }

    /// Test seam mirroring `ClaudeRuntime.drainForTesting()`, so runtime tests need no clock.
    func drainForTesting() {
        for source in sources.values { source.watcher?.drain() }
        names?.drain()
    }
}
