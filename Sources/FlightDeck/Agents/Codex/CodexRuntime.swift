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
    private struct Attachment {
        let onEvent: (AgentEvent) -> Void
        let watcher: CodexRolloutWatcher?
    }

    private var attachments: [UUID: Attachment] = [:]
    private let clock: WatchClock?
    private let indexURL: URL

    /// Built on first attach and dropped with the last one, so a user with no codex tabs
    /// never has a watcher ticking over codex's index.
    private var names: CodexNameWatcher?

    init(clock: WatchClock? = nil, indexURL: URL = CodexNameWatcher.defaultIndexURL) {
        self.clock = clock
        self.indexURL = indexURL
    }

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        let id = binding.conversationID

        var watcher: CodexRolloutWatcher?
        if let url = binding.transcriptURL {
            watcher = CodexRolloutWatcher(url: url, clock: clock, onEvent: onEvent)
            watcher?.start()
        }
        // Stopped explicitly rather than left to the replaced `Attachment` being released: it
        // survives its owner by its registration on the shared `WatchClock`, and although that
        // registration is weak and self-prunes, an invariant that holds only because of a
        // retention detail two files away is not one to lean on.
        attachments[id]?.watcher?.stop()
        attachments[id] = Attachment(onEvent: onEvent, watcher: watcher)

        // Registered even when there is no rollout to tail: a tab still has a name.
        nameWatcher().register(id) { onEvent(.title($0)) }
    }

    func detach(_ binding: AgentBinding) {
        let id = binding.conversationID
        attachments[id]?.watcher?.stop()
        attachments[id] = nil

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
        for attachment in attachments.values { attachment.watcher?.drain() }
        names?.drain()
    }
}
