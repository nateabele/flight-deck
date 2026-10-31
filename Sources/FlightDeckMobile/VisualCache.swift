import CryptoKit
import FleetKit
import Foundation

/// Which file of which revision of which visual.
struct VisualKey: Hashable, Sendable {
    let visualID: String
    let revision: Int
    /// Relative to the revision folder on the Mac (`export/index.html`).
    let path: String
}

/// The phone's copy of visual files (planning v2 §10, P2a V3), on disk under Caches, so the OS
/// may reclaim it and nothing here is ever the only copy.
///
/// **A revision never changes once final, so a hit never goes stale.** That is why entries are
/// kept indefinitely and the only thing that removes one is the byte budget, least recently
/// used first and across revisions and visuals alike. An older revision of a diagram costs
/// the same as a newer one and is less likely to be opened again.
///
/// **Nothing unchecked is stored.** `store` hashes the bytes and refuses a mismatch with the
/// SHA-256 the Mac's manifest promised, so a truncated or tampered transfer is never a hit
/// later. The same digest is part of the file's name, which is what makes a lookup honest:
/// the key is `(visualID, revision, path)` but a hit also needs the content the manifest now
/// promises, so a second Mac that reuses `flow` r1 for other content misses instead of showing
/// the first Mac's picture.
///
/// **No name in a file's path comes from the Mac.** The id must pass the plan fence's own rule,
/// the revision is a number, the path is hashed, and the digest must be 64 lowercase hex
/// characters, so none of them can steer a write out of the cache folder.
final class VisualCache: @unchecked Sendable {
    /// What the phone keeps unless told otherwise: a dozen big comps, a few hundred snapshots.
    static let defaultBudget: Int64 = 128 * 1_048_576

    private let directory: URL
    private let budget: Int64
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    /// The app's one cache, under `Caches/visuals`.
    static let shared: VisualCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return VisualCache(directory: caches.appendingPathComponent("visuals", isDirectory: true), budget: defaultBudget)
    }()

    /// `now` is injected so a test orders "least recently used" without racing file timestamps.
    init(directory: URL, budget: Int64 = VisualCache.defaultBudget, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.budget = budget
        self.now = now
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `bytes` are in the cache for `key` with exactly the content `sha256` names.
    func contains(_ key: VisualKey, sha256: String) -> Bool {
        lock.withLock { fileURL(key, sha256: sha256).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }

    /// The bytes for `key` if the cache holds the content `sha256` names; touches them, so a file
    /// being looked at is the last to go.
    func data(for key: VisualKey, sha256: String) -> Data? {
        lock.withLock {
            guard let url = fileURL(key, sha256: sha256), let data = try? Data(contentsOf: url) else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            return data
        }
    }

    /// Keeps `data` for `key` if its SHA-256 is `sha256`; false (and nothing written) otherwise.
    /// Evicts least recently used files until the cache fits its budget again, never the one just
    /// written: a file bigger than the whole budget is still kept, alone, for the one viewer
    /// that asked for it.
    @discardableResult
    func store(_ data: Data, for key: VisualKey, sha256: String) -> Bool {
        lock.withLock {
            guard Self.sha256Hex(data) == sha256, let url = fileURL(key, sha256: sha256) else { return false }
            let fm = FileManager.default
            let folder = url.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                // Other content under this key is the key's old content; it must not sit beside the new.
                let stem = url.lastPathComponent.split(separator: ".").first.map(String.init) ?? ""
                for old in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix(stem + ".") && old != url.lastPathComponent {
                    try? fm.removeItem(at: folder.appendingPathComponent(old))
                }
                try data.write(to: url, options: .atomic)
                try fm.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            } catch {
                return false
            }
            evict(keeping: url)
            return true
        }
    }

    /// Bytes on disk across every visual and revision.
    func totalBytes() -> Int64 { lock.withLock { entries().reduce(0) { $0 + $1.size } } }

    // MARK: - Private

    private func fileURL(_ key: VisualKey, sha256: String) -> URL? {
        guard VisualFenceInfo.isValidID(key.visualID), key.revision >= 0, Self.isDigest(sha256) else { return nil }
        return directory
            .appendingPathComponent(key.visualID, isDirectory: true)
            .appendingPathComponent("r\(key.revision)", isDirectory: true)
            .appendingPathComponent(Self.sha256Hex(Data(key.path.utf8)) + "." + sha256)
    }

    private static func isDigest(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private struct Entry { let url: URL; let size: Int64; let used: Date }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var out: [Entry] = []
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append(Entry(url: url, size: Int64(v.fileSize ?? 0), used: v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    private func evict(keeping keep: URL) {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > budget else { return }
        all.removeAll { $0.url.standardizedFileURL == keep.standardizedFileURL }
        for entry in all.sorted(by: { $0.used < $1.used }) {
            guard total > budget else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }
}
