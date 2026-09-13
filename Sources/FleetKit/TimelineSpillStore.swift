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

    /// Merge `bodies` into the file. Appends rather than replacing, so successive spills as the
    /// window moves accumulate rather than clobbering earlier records.
    public func write(_ bodies: [String: TimelineItem.Body]) {
        guard !bodies.isEmpty else { return }
        queue.sync {
            var current = readAll()
            for (id, body) in bodies { current[id] = body }
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: fileURL, options: .atomic)
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
