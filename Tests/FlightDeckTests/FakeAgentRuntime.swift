import Foundation
@testable import FlightDeck

/// Lets store tests exercise both agents with no processes, no files and no clock —
/// the same role `SpyInjector` plays for text injection.
@MainActor
final class FakeAgentRuntime: AgentRuntime {
    private var handlers: [UUID: (AgentEvent) -> Void] = [:]
    private(set) var attached: [UUID] = []
    private(set) var detached: [UUID] = []

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        handlers[binding.conversationID] = onEvent
        attached.append(binding.conversationID)
    }

    func detach(_ binding: AgentBinding) {
        handlers[binding.conversationID] = nil
        detached.append(binding.conversationID)
    }

    func emit(_ event: AgentEvent, for conversationID: UUID) {
        handlers[conversationID]?(event)
    }
}
