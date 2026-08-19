import Foundation

/// Claude's runtime: one `TranscriptWatcher` per attached tab (the transcript is per
/// conversation) plus the single shared `SessionStatusWatcher` (the registry is not).
@MainActor
final class ClaudeRuntime: AgentRuntime {
    private struct Attachment {
        let onEvent: (AgentEvent) -> Void
        let watcher: TranscriptWatcher?
    }

    private var attachments: [UUID: Attachment] = [:]
    private let clock: WatchClock?

    init(clock: WatchClock? = nil) {
        self.clock = clock
    }

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        let id = binding.conversationID
        var watcher: TranscriptWatcher?
        if let url = binding.transcriptURL {
            watcher = TranscriptWatcher(
                sessionID: id,
                url: url,
                clock: clock,
                onTitle: { onEvent(.title($0)) },
                onSubagentCount: { onEvent(.subagentCount($0)) }
            )
            watcher?.start()
        }
        // Stopped explicitly rather than left to the replaced `Attachment` being released:
        // it survives its owner by its registration on the shared `WatchClock`, and although
        // that registration is weak and self-prunes, an invariant that holds only because of
        // a retention detail two files away is not one to lean on.
        attachments[id]?.watcher?.stop()
        attachments[id] = Attachment(onEvent: onEvent, watcher: watcher)
    }

    func detach(_ binding: AgentBinding) {
        attachments[binding.conversationID]?.watcher?.stop()
        attachments[binding.conversationID] = nil
    }

    /// Fan-out point for the shared status watcher. `SessionStore` owns the one
    /// `SessionStatusWatcher` and hands its output here rather than this type owning a
    /// second one — the registry must be scanned once per tick, not once per tab.
    func ingest(_ entries: [pid_t: ClaudeStatusFile.Entry]) {
        for entry in entries.values {
            guard let attachment = attachments[entry.sessionID] else { continue }
            attachment.onEvent(.activity(entry.activity))
        }
    }

    /// Test seam mirroring `TranscriptWatcher.drain()`, so runtime tests need no clock.
    func drainForTesting() {
        for attachment in attachments.values { attachment.watcher?.drain() }
    }
}
