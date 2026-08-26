import Foundation
@testable import FlightDeck

/// Lets store tests exercise both agents with no processes, no files and no clock —
/// the same role `SpyInjector` plays for text injection.
@MainActor
final class FakeAgentRuntime: AgentRuntime {
    private var handlers: [AttachmentToken: (AgentEvent) -> Void] = [:]
    private(set) var attached: [UUID] = []
    private(set) var detached: [UUID] = []

    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken {
        let token = AttachmentToken(conversationID: binding.conversationID, tab: tab)
        handlers[token] = onEvent
        attached.append(binding.conversationID)
        return token
    }

    func detach(_ token: AttachmentToken) {
        handlers[token] = nil
        detached.append(token.conversationID)
    }

    /// Delivers to every subscriber on that conversation, exactly as a real source does.
    func emit(_ event: AgentEvent, for conversationID: UUID) {
        for (token, handler) in handlers where token.conversationID == conversationID {
            handler(event)
        }
    }

    /// Delivers to exactly one subscriber — the whole point of `AttachmentToken` existing.
    /// `emit(_:for:)` above still fans out by conversation, which is correct for it (it
    /// simulates a real source, and a real source is one per conversation) but useless for
    /// proving that two tabs sharing one conversation stay independent once the *store*
    /// routes by token.
    func emit(_ event: AgentEvent, to token: AttachmentToken) {
        handlers[token]?(event)
    }
}
