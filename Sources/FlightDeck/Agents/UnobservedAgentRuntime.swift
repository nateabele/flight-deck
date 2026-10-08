import Foundation

/// The runtime of an agent whose tabs Flight Deck cannot observe yet: it hands out tokens and
/// never reports an event.
///
/// Exists so `SessionStore.runtime(for:)` can answer every `AgentID` with a real arm instead of
/// degrading grok and gemini to a `ClaudeRuntime` — which would tail a claude transcript path
/// nothing writes and leave the tab's status to whatever that path happened to hold. Silence
/// is the honest answer for a stub adapter (unify brief P0): the tab shows no activity rather
/// than someone else's. Tracks G and M replace it with a runtime that reads their CLI.
@MainActor
final class UnobservedAgentRuntime: AgentRuntime {
    func attach(_ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void) -> AttachmentToken {
        AttachmentToken(conversationID: binding.conversationID, tab: tab)
    }

    func detach(_ token: AttachmentToken) {}
}
