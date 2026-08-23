import Foundation

/// One message a client handed to the Mac, and how far it has got.
public struct PromptOutboxEntry: Identifiable, Equatable, Sendable {
    /// **Three states and no fourth.** "The Mac has it" is not distinguished from "the agent
    /// has it", because the Mac cannot tell you the difference — `ack` means dispatched, not
    /// done — and the transcript settles it either way within a turn.
    public enum State: Equatable, Sendable {
        /// Handed to the socket; no answer yet.
        case sending
        /// The Mac acked. It will be typed when the agent's input box is free, which may be
        /// a turn boundary away.
        case accepted
        /// It will not be typed, and this is why. Copy, not a code.
        case failed(String)
    }

    /// The idempotency token, which is also the identity: minted once per composed message
    /// and the thing `SessionStore.submitPrompt` dedupes on.
    public let id: UUID
    public let text: String
    public var state: State

    public init(id: UUID, text: String, state: State = .sending) {
        self.id = id
        self.text = text
        self.state = state
    }
}

/// The messages a session screen has sent and not yet seen come back.
///
/// **There is no optimistic echo into the timeline, and that is the design rather than a
/// simplification.** The timeline is answered from files on request (spec §6): every item in
/// it is a record the agent has already written. A row the phone drew for a prompt the agent
/// has not taken yet would be a claim the transcript does not support — carrying a
/// `"<offset>#<index>"` id no file produced, inside a `TimelineFeed` whose merge assumes
/// exactly the opposite. So an outbox entry is drawn *beside* the conversation, visibly not
/// part of it, and it disappears at the one moment it becomes true: when the agent's own
/// transcript comes back holding it.
///
/// **`TimelineItem.Kind.prompt` is NOT what this renders as**, and the temptation is worth
/// naming because the spec invites it. That case belongs to §9's prompt *bridging* — a
/// permission request the agent raised and is blocked on, travelling agent → user, which is
/// the opposite direction. Nothing emits it yet; squatting on it here would make it unusable
/// for the thing it was reserved for. A message a person typed is a `.userTurn`, which is
/// what both mappers already emit.
public struct PromptOutbox: Equatable, Sendable {
    public private(set) var entries: [PromptOutboxEntry] = []

    /// The ids of the `.userTurn` items already on screen when each entry was filed.
    ///
    /// This is what makes confirmation honest. Matching on text alone would let somebody
    /// else's older "yes", already sitting in the conversation, retire a "yes" the Mac has
    /// not even read — the send would look confirmed before the frame left the phone.
    private var witnessed: [UUID: Set<String>] = [:]

    public init() {}

    /// Whether anything is still waiting on the Mac. Drives the Send button, so a double tap
    /// cannot become two messages.
    public var isSending: Bool { entries.contains { $0.state == .sending } }

    /// Files a new entry and records what the conversation already held.
    public mutating func add(id: UUID, text: String, alreadyShowing items: [TimelineItem]) {
        witnessed[id] = Set(items.lazy.filter { $0.kind == .userTurn }.map(\.id))
        entries.append(PromptOutboxEntry(id: id, text: text))
    }

    /// The Mac acked. A token with no entry is a no-op — an entry can be dismissed while its
    /// answer is in flight.
    public mutating func accept(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = .accepted
    }

    /// It will not be typed. The entry STAYS, carrying the reason: an outbox that cleared
    /// itself on failure would be a message that vanished, which is the failure this whole
    /// mechanism exists to prevent.
    public mutating func fail(_ id: UUID, _ message: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = .failed(message)
    }

    /// The reader has read the failure and wants the row gone.
    public mutating func dismiss(_ id: UUID) {
        entries.removeAll { $0.id == id }
        witnessed.removeValue(forKey: id)
    }

    /// Retires every entry the transcript now holds.
    ///
    /// **Matched on kind, on text, AND on not-having-been-there.** Kind, because the agent
    /// quoting a message back is not the message landing. Text, because that is all the two
    /// sides share — the item's id is a byte offset the phone never predicted. And the
    /// witness set, because a conversation that already contains the same words would
    /// otherwise confirm a send the Mac has not read.
    ///
    /// **`state` is deliberately not consulted.** A prompt whose `ack` was lost — the exact
    /// case the screen model's deadline produces — may still have been typed, and when its
    /// turn appears the honest thing is to clear the row rather than leave it accusing the
    /// Mac of something that worked.
    ///
    /// One arriving turn retires at most one entry, in send order. Sending the same word
    /// twice is two messages and two turns are coming; clearing both on the first would erase
    /// a message the Mac has not typed yet.
    ///
    /// A `reset` page reissues every id, so an entry whose witness set no longer describes
    /// anything is retired by the next matching turn rather than stranded — which is why the
    /// test is "not in the recorded set" and not "after the recorded newest".
    public mutating func reconcile(with items: [TimelineItem]) {
        guard !entries.isEmpty else { return }
        var unclaimed = items.filter { $0.kind == .userTurn }
        var retired: Set<UUID> = []
        for entry in entries {
            let seen = witnessed[entry.id] ?? []
            guard let index = unclaimed.firstIndex(where: {
                $0.body.text == entry.text && !seen.contains($0.id)
            }) else { continue }
            unclaimed.remove(at: index)
            retired.insert(entry.id)
        }
        guard !retired.isEmpty else { return }
        entries.removeAll { retired.contains($0.id) }
        for id in retired { witnessed.removeValue(forKey: id) }
    }
}
