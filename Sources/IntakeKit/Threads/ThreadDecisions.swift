import Foundation

/// What one ask thread tells the next round (spec §11): its title, its anchor, and the latest
/// `decision` line it reached since the last round. An accepted diff already reaches the round
/// as the human's edit; the decision is the reason behind it, so a refine round that reads it
/// keeps the change instead of quietly undoing it.
public struct ThreadDecision: Equatable, Sendable {
    public var title: String
    /// The anchored passage; nil for a thread on the whole plan.
    public var quote: String?
    public var section: String?
    /// nil when the thread decided nothing since the last round and is here for its edit alone.
    public var decision: String?
    /// One of the thread's accepted diffs is in the head plan's edit layer.
    public var acceptedEdit: Bool

    public init(title: String, quote: String?, section: String?, decision: String?, acceptedEdit: Bool) {
        self.title = title
        self.quote = quote
        self.section = section
        self.decision = decision
        self.acceptedEdit = acceptedEdit
    }
}

public enum ThreadDecisions {
    /// One entry per thread touched since `lastRound` (the newest checkpoint's landing; nil
    /// before any): the latest non-empty decision of a turn that ended after it, and whether an
    /// `accepted` source names the thread. A resolved thread never feeds rounds (spec §5), and
    /// a thread with neither says nothing. In the reader's order, oldest thread first.
    public static func since(_ lastRound: Date?, reader: any ThreadStoreReading, accepted: [ThreadEditSource]) -> [ThreadDecision] {
        let edited = Set(accepted.map(\.thread))
        return reader.threads().compactMap { record in
            guard record.status != .resolved else { return nil }
            let decision = reader.turns(record.id)
                .filter { turn in
                    guard !turn.isDivider, let ended = turn.endedAt else { return false }
                    return lastRound.map { ended > $0 } ?? true
                }
                .sorted { $0.seq < $1.seq }
                .compactMap { $0.decision?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last { !$0.isEmpty }
            let acceptedEdit = edited.contains(record.id)
            guard decision != nil || acceptedEdit else { return nil }
            return ThreadDecision(title: record.title, quote: record.anchor.note?.quote, section: record.anchor.note?.section,
                                  decision: decision, acceptedEdit: acceptedEdit)
        }
    }
}
