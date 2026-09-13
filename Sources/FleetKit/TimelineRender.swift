import Foundation

/// One row's worth of conversation: an item, plus the result that answers it when the item is a
/// call and the window holds one.
///
/// In `FleetKit` rather than in the phone's view for the reason `TimelineFeed`'s doc comment
/// gives: the fold's one hard invariant — pairing a `toolResult` with its `toolCall` across a
/// page boundary and never dropping a result whose call is on an adjacent page — is exactly the
/// kind of thing the macOS unit suite must be able to hold, not something behind a booted
/// simulator. The ghost-append that needs `PromptOutboxEntry` stays in the model layer as a thin
/// wrapper over this pure fold; this type and `TimelineRender.entries(from:)` know nothing about
/// the outbox.
public struct TimelineEntry: Identifiable, Hashable, Sendable {
    public let item: TimelineItem
    public let result: TimelineItem?
    public var id: String { item.id }

    /// A synthetic entry for a `.delivered` outbox message, never a record the agent wrote.
    /// Detected by id prefix rather than a stored field: the id is the one thing the ghost
    /// wrapper controls, and a second flag would be a second place the two could disagree. The
    /// wrapper lives in `SessionTimelineModel`; the pure fold here never produces one.
    public var isGhost: Bool { item.id.hasPrefix("ghost:") }

    public init(item: TimelineItem, result: TimelineItem?) {
        self.item = item
        self.result = result
    }
}

public enum TimelineRender {
    /// Folds every tool result into the call it answers, so a command and its output are one row
    /// rather than two that read as two unrelated events.
    ///
    /// **Paired on `callID` — the agent's own id — and never on position.** A session running two
    /// tools at once interleaves their records, so "the next result" is a different call's output
    /// about half the time.
    ///
    /// **A result is only folded away when its call is actually here.** A page boundary can land
    /// between the two, and dropping a result whose call is on the previous page would delete
    /// content from the screen. So the set of calls present is what decides, not merely the
    /// result having an id.
    ///
    /// **Only the first result for a call folds.** A second result for the same call is not the
    /// pair the call is missing — it is duplicate content — so it stays its own row rather than
    /// vanishing silently.
    public static func entries(from items: [TimelineItem]) -> [TimelineEntry] {
        var resultsByCall: [String: TimelineItem] = [:]
        var callsPresent: Set<String> = []
        for item in items {
            guard let callID = item.body.callID else { continue }
            switch item.kind {
            case .toolResult: if resultsByCall[callID] == nil { resultsByCall[callID] = item }
            case .toolCall: callsPresent.insert(callID)
            default: break
            }
        }
        return items.compactMap { item -> TimelineEntry? in
            guard let callID = item.body.callID else { return TimelineEntry(item: item, result: nil) }
            switch item.kind {
            case .toolCall:
                return TimelineEntry(item: item, result: resultsByCall[callID])
            case .toolResult:
                let isWinner = resultsByCall[callID]?.id == item.id
                return (isWinner && callsPresent.contains(callID))
                    ? nil : TimelineEntry(item: item, result: nil)
            default:
                return TimelineEntry(item: item, result: nil)
            }
        }
    }
}
