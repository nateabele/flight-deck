import FleetKit
import SwiftUI

/// The link-detection memo for the plain-text rows on one screen — `.thinking`, `.toolResult`,
/// `.systemNotice`, `.prompt`, `.unknown`. Mirrors `TimelineSegmentCache`, one axis narrower:
/// a plain body has no expansion state and no width to bucket by, so the key is just the item
/// id.
///
/// **Why this exists at all.** `NSDataDetector` walks every character of the body it is handed,
/// and a `.toolResult` can be tens of kilobytes. Recomputing that on every re-render of a `List`
/// cell — which SwiftUI does far more often than the visible content actually changes — is the
/// same defect `TimelineSegmentCache`'s own doc comment describes for the segmenter, one call
/// site over.
@MainActor
final class TimelineLinkCache {
    private let capacity: Int
    private var store: [String: AttributedString] = [:]
    private var order: [String] = []  // least-recently-used first
    /// How many times the detector actually ran — a miss. Tests assert on it.
    private(set) var computeCount = 0

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    func linked(for item: TimelineItem) -> AttributedString {
        // A spilled item rehydrates with a placeholder body (see `TimelineItemBody
        // .isPlaceholder`) before the real one lands — caching that placeholder's text under
        // the item's permanent id would keep serving it after rehydration replaces the body,
        // since nothing evicts an entry just because the item it was keyed on changed
        // underneath it. Recompute every call instead of storing it: a placeholder is rare and
        // brief next to steady-state scrolling, so the repeat detector cost is cheaper than the
        // staleness bug.
        guard !item.body.isPlaceholder else {
            computeCount += 1
            return TimelineStyle.linkedPlainText(item.body.text)
        }
        if let hit = store[item.id] {
            touch(item.id)
            return hit
        }
        computeCount += 1
        let value = TimelineStyle.linkedPlainText(item.body.text)
        store[item.id] = value
        order.append(item.id)
        evictIfNeeded()
        return value
    }

    private func touch(_ id: String) {
        if let index = order.firstIndex(of: id) { order.remove(at: index) }
        order.append(id)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            store.removeValue(forKey: oldest)
        }
    }
}
