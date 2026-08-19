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

        // Reconcile-on-first-contact. A tab whose codex sat behind the directory-trust or
        // hooks-review prompt produced nothing until the user cleared it, so its title and
        // status are stale by exactly one read. Doing this on first contact rather than on a
        // timer means no polling and no arbitrary delay.
        if !attachment.hasReconciled {
            attachment.hasReconciled = true
            Task { await self.reconcile(id) }
        }

        let events = CodexEventMapper.events(method: method, params: params, state: &attachment.state)
        attachments[id] = attachment
        for event in events { attachment.onEvent(event) }
    }
}
