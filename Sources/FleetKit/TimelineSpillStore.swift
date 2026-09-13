import Foundation

/// A per-session cache of spilled timeline body text, keyed by item id, under `Caches`.
///
/// Part of the hard memory ceiling: when a single session's resident text grows past a byte
/// budget, `TimelineFeed.spill` swaps the full `body.text` of items far from the visible window
/// for a placeholder preview and hands the originals here to persist. On approach,
/// `rehydrate` reads them back synchronously — local and fast, no loading flash. The file lives
/// under `Caches`, so the OS may purge it under pressure; a purged read returns empty and the
/// model falls back to a wire re-fetch of that offset range.
///
/// `TimelineItem.Body` is `Codable`, so a record is the body itself — nothing bespoke to keep in
/// sync with the wire type.
///
/// The file is never allowed to become the whole transcript: `remove` prunes an id the moment
/// its body is back in memory, so it tracks the currently-spilled set, not everything that was
/// ever spilled. And it never outlives a pairing: `purgeAll` clears every session's file at once
/// for `FleetModel.unpair()`, and `purge` clears one session's when its cursor's transcript is
/// gone (a `reset` page — see `SessionTimelineModel`), since spilled bodies keyed to byte offsets
/// that no longer mean what they meant are worse than useless.
public final class TimelineSpillStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "flightdeck.timeline-spill")

    public init(session: UUID, directory: URL? = nil) {
        let base = directory ?? Self.defaultCachesDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("\(session.uuidString).json", isDirectory: false)
    }

    private static func defaultCachesDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("FlightDeckTimelineSpill", isDirectory: true)
    }

    /// Removes the whole on-disk spill cache — every session's file, not just one. Called on
    /// `FleetModel.unpair()`: a spilled body is transcript text parked on disk rather than in
    /// memory, and it must not survive the same revocation that clears everything else that
    /// pairing held. Wrapped in the same resilience as `purge()` below: a cache that was never
    /// created, or is already gone, is success, not a throw.
    public static func purgeAll(directory: URL? = nil) {
        let base = directory ?? defaultCachesDirectory()
        try? FileManager.default.removeItem(at: base)
    }

    /// Merge `bodies` into the file. Appends rather than replacing, so successive spills as the
    /// window moves accumulate rather than clobbering earlier records.
    ///
    /// **Dispatched with `queue.async`, not `queue.sync`.** This runs off `reconcileSpill()`'s
    /// `@MainActor` path, and the encode-and-write must not block scroll while a large session's
    /// items get merged into the file. Safe because `queue` is SERIAL: a later `read`, `remove`
    /// or `purge` on *this* instance is enqueued after this block, and a serial queue runs its
    /// blocks in FIFO order — so any of those calls still observes this write's result, never a
    /// race, exactly as if it had been synchronous. And if this block never gets to run at all —
    /// the app is killed before it does — nothing is lost for good: a store miss reads exactly
    /// like a `Caches` file the OS purged under pressure, and the model's wire-refetch fallback
    /// (Task 4.4) re-reads that offset from the Mac. This cache is never the only copy.
    public func write(_ bodies: [String: TimelineItem.Body]) {
        guard !bodies.isEmpty else { return }
        queue.async {
            var current = self.readAll()
            for (id, body) in bodies { current[id] = body }
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    /// The bodies for `ids` that the cache still holds. A missing id — never written, or purged
    /// — is simply absent; the caller's wire fallback covers it.
    public func read(_ ids: Set<String>) -> [String: TimelineItem.Body] {
        queue.sync {
            let all = readAll()
            return all.filter { ids.contains($0.key) }
        }
    }

    /// Drop `ids` from the cache. Called after a rehydrate puts them back in memory: a body the
    /// feed is holding resident again does not need to keep growing this file, so the file stays
    /// close to the size of whatever is *currently* spilled rather than the whole session's
    /// history of ever having been spilled.
    public func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        queue.sync {
            var current = readAll()
            for id in ids { current.removeValue(forKey: id) }
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    public func purge() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func readAll() -> [String: TimelineItem.Body] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: TimelineItem.Body].self, from: data)
        else { return [:] }
        return decoded
    }
}
