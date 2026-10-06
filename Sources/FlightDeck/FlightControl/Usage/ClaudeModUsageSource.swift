import Foundation
import IntakeKit

/// Reads the files the bundled usage mod writes, one per claude tab, into
/// `ClaudePluginLocation.usageDirectory`.
///
/// Polled, not watched: `UsageService` already ticks every few seconds and a directory listing
/// is cheap, while an FSEvents stream would be one more lifetime to manage for no gain. A file
/// is decoded only when its modification date moved, and is recorded as seen only after it
/// decoded — the mod's write and this read can interleave, and a torn read must be retried on
/// the next scan, not mistaken for "already handled".
@MainActor
final class ClaudeModUsageSource {
    let directory: URL
    private var seen: [String: Date] = [:]

    init(directory: URL) { self.directory = directory }

    /// Files named `<uuid>.json` that changed since the last scan. The stem is the FD tab id or
    /// claude's own session id; `UsageService` decides which.
    func scan() -> [(stem: UUID, file: ModUsageFile)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [(stem: UUID, file: ModUsageFile)] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let stem = UUID(uuidString: String(name.dropLast(5))) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  seen[name] != mtime,
                  let data = try? Data(contentsOf: url),
                  let file = ModUsageFile.decode(data) else { continue }
            seen[name] = mtime
            out.append((stem, file))
        }
        return out
    }

    /// One file per tab ever opened would grow forever; a week-old file belongs to a tab that is
    /// long gone, and its reading is stale thirty minutes after it was written anyway.
    func prune(olderThan age: TimeInterval, now: Date) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) > age else { continue }
            try? fm.removeItem(at: url)
            seen.removeValue(forKey: name)
        }
    }
}
