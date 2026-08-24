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

    init(clock: WatchClock? = nil) {
        self.clock = clock
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
                onSubagentCount: { subscribers.emit(.subagentCount($0)) }
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

    /// Deprecated conversation-keyed API, kept only until `SessionStore` moves to tokens
    /// (Task 5) so the suite stays green mid-migration. Removed in Task 6.
    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        _ = attach(binding, for: binding.conversationID, onEvent: onEvent)
    }

    func detach(_ binding: AgentBinding) {
        detach(AttachmentToken(conversationID: binding.conversationID, tab: binding.conversationID))
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
