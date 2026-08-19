import Foundation

/// An event with the position it holds in the northbound stream. The sequence is what a
/// client sends back as `hello(lastSeq:)` to resume.
public struct SequencedEvent: Codable, Equatable, Sendable {
    public let seq: Int
    public let event: FleetEvent

    public init(seq: Int, event: FleetEvent) {
        self.seq = seq
        self.event = event
    }
}

extension FleetReplay {
    /// The fold, keeping each surviving event's sequence number.
    ///
    /// Folding drops events, so the last survivor's sequence can be lower than the newest
    /// one issued. That is deliberate and harmless: a client's `lastSeq` is simply the
    /// highest it has seen, so a fold that discards the tail only makes its *next* resume
    /// window slightly wider. Inventing a synthetic sequence for a folded frame would be
    /// the alternative, and it would let a client claim to have applied an event it never
    /// received.
    public static func fold(_ events: [SequencedEvent]) -> [SequencedEvent] {
        keptIndices(events.map(\.event)).map { events[$0] }
    }
}
