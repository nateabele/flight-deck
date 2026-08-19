import Foundation

/// Codex's observation half: one app-server for the whole app, notifications routed by
/// `threadId`.
///
/// One connection rather than one per tab is not an optimisation — a thread lives in the
/// app-server process that created it, so a per-call process would lose every thread it
/// made the moment it exited.
@MainActor
final class CodexRuntime: AgentRuntime {
    private struct Attachment {
        let onEvent: (AgentEvent) -> Void
        var state = CodexThreadState()
        var hasReconciled = false
        /// Counts notifications handled for this thread. The only thing it has to be is
        /// strictly increasing — it is compared for equality, never read as a quantity.
        var version = 0
        /// The `version` an in-flight reconcile was scheduled against; nil when none is.
        /// Reset by `attach`, so a reconcile answering for a replaced attachment is dropped.
        var reconcilingAt: Int?
    }

    private var attachments: [UUID: Attachment] = [:]
    private let rpc: CodexRPC

    /// Re-reads authoritative title and status for a thread. Injected so tests need no
    /// server; production wires it to `thread/read`.
    var reconcile: (UUID) async -> Void = { _ in }

    init(rpc: CodexRPC) {
        self.rpc = rpc
        rpc.onNotification = { [weak self] method, params in
            self?.handle(method: method, params: params)
        }
    }

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        attachments[binding.conversationID] = Attachment(onEvent: onEvent)
    }

    func detach(_ binding: AgentBinding) {
        attachments[binding.conversationID] = nil
    }

    func handle(method: String, params: [String: Any]) {
        guard let raw = params["threadId"] as? String,
              let id = UUID(uuidString: raw),
              var attachment = attachments[id]
        else { return }

        // Bumped before anything is dispatched, so the version a reconcile is scheduled
        // against already counts the notification that scheduled it. See `applyReconciled`.
        attachment.version += 1

        // Reconcile-on-first-contact. A tab whose codex sat behind the directory-trust or
        // hooks-review prompt produced nothing until the user cleared it, so its title and
        // status are stale by exactly one read. Doing this on first contact rather than on a
        // timer means no polling and no arbitrary delay.
        if !attachment.hasReconciled {
            attachment.hasReconciled = true
            attachment.reconcilingAt = attachment.version
            Task { await self.reconcile(id) }
        }

        let events = CodexEventMapper.events(method: method, params: params, state: &attachment.state)
        attachments[id] = attachment
        for event in events { attachment.onEvent(event) }
    }

    /// Delivers what `reconcile` read — but only if nothing has moved under it.
    ///
    /// This is the ordering guard the injected `reconcile` cannot provide for itself.
    /// `reconcile` is `async` and `handle` is not, so `Task { await reconcile(id) }` only
    /// *schedules*: the notification that triggered it delivers its own events first, and any
    /// notification arriving before that task gets to run lands first too. A `thread/read`
    /// issued at that moment can therefore describe a thread that has already moved on, and
    /// writing its answer straight through would flick a tab's title or status back to an
    /// older value seconds after the user watched it change.
    ///
    /// So the answer is version-checked rather than raced. `version` counts notifications for
    /// this thread; `reconcilingAt` records what it was when the read was scheduled; a
    /// mismatch means a newer notification has already said something the read cannot know
    /// about. Dropping is right rather than merely safe there — the notification is strictly
    /// newer than a read that was already in flight when it arrived — and costs nothing,
    /// because a thread that is emitting notifications is not the silent one reconcile exists
    /// for.
    ///
    /// Handed back as ordinary events rather than written anywhere: a reconcile carries the
    /// same news a notification does, so routing it through the attachment keeps one path
    /// into the store for both. It is also why this is the runtime's method and not the
    /// store's — the counter the guard reads lives here.
    func applyReconciled(title: String?, activity: SessionActivity?, for conversationID: UUID) {
        guard var attachment = attachments[conversationID],
              attachment.reconcilingAt == attachment.version
        else { return }
        // Cleared so a second delivery for the same read cannot apply, and so the next
        // mismatch is a mismatch rather than a fresh match at version 0.
        attachment.reconcilingAt = nil
        attachments[conversationID] = attachment
        if let title { attachment.onEvent(.title(title)) }
        if let activity { attachment.onEvent(.activity(activity)) }
    }
}
