import Foundation

/// One tab's subscription to one conversation's event source.
///
/// Identity, not a value match. The 2026-08-23 rename spread because the store decided who
/// an event belonged to by scanning a dictionary for entries whose `conversationID` equalled
/// the event's — so a single wrong entry widened one event's blast radius to every tab on the
/// account. A token is handed out by the runtime at `attach` and handed back at `detach`, so
/// an event can only ever reach a tab that asked for it.
struct AttachmentToken: Hashable, Sendable {
    let conversationID: UUID
    let tab: UUID
}

/// The subscribers on one conversation's source.
///
/// Shared by every `AgentRuntime` rather than reimplemented per agent: both runtimes
/// previously kept `[conversationID: Attachment]`, so a second tab attaching to a
/// conversation *replaced* the first — stopping its watcher and orphaning its closure. Any
/// future agent that copied that shape would reintroduce the defect, so the mechanics live
/// here and the runtimes hold one of these per source.
@MainActor
final class SubscriberList {
    private var handlers: [AttachmentToken: (AgentEvent) -> Void] = [:]

    var isEmpty: Bool { handlers.isEmpty }

    func add(_ token: AttachmentToken, _ onEvent: @escaping (AgentEvent) -> Void) {
        handlers[token] = onEvent
    }

    @discardableResult
    func remove(_ token: AttachmentToken) -> Bool {
        handlers.removeValue(forKey: token) != nil
    }

    func emit(_ event: AgentEvent) {
        for handler in handlers.values { handler(event) }
    }
}
