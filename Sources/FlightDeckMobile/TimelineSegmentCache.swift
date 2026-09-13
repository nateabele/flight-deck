import FleetKit

/// The clamped-segments memo for the prose rows on one screen.
///
/// A row's segmenter used to run three times per render — through `expandsInPlace`, through
/// `segments`, and through the accessibility label — each splitting the full body again, on
/// every re-render and every poll tick. This caches the split, keyed by exactly what changes
/// it: the item id, whether the row is expanded, and the width bucket the row laid out at.
///
/// Bounded (visible rows plus a margin) and evicted least-recently-used, so a long scroll never
/// grows it without bound. Owned by the screen and handed to each row, so it outlives cell
/// recycling and is drivable by a test with no window.
@MainActor
final class TimelineSegmentCache {
    struct Key: Hashable {
        let id: String
        let expanded: Bool
        let widthBucket: Int
    }

    private let capacity: Int
    private var store: [Key: TimelineSegmenter.Clamped] = [:]
    private var order: [Key] = []  // least-recently-used first
    /// How many times the underlying segmenter actually ran — a miss. Tests assert on it.
    private(set) var computeCount = 0

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    func clamped(for item: TimelineItem, expanded: Bool, widthBucket: Int) -> TimelineSegmenter.Clamped {
        let key = Key(id: item.id, expanded: expanded, widthBucket: widthBucket)
        if let hit = store[key] {
            touch(key)
            return hit
        }
        computeCount += 1
        let value = TimelineStyle.clampedProse(for: item, expanded: expanded)
        store[key] = value
        order.append(key)
        evictIfNeeded()
        return value
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            store.removeValue(forKey: oldest)
        }
    }
}
