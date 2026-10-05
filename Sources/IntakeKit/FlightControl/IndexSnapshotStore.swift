import Foundation

public struct SnapshotRef: Equatable, Hashable, Sendable {
    public var url: URL
    public var stamp: String
    public var date: Date
    public var rolledBack: Bool
    public init(url: URL, stamp: String, date: Date, rolledBack: Bool) {
        self.url = url; self.stamp = stamp; self.date = date; self.rolledBack = rolledBack
    }
}

public enum IndexStoreError: Error, Equatable, Sendable { case nothingToRollBackTo }

/// `capability-index/`: one `<stamp>.json` per snapshot. The newest one that loads is current —
/// the only rule. Rollback renames the current file to `<stamp>.rolledback.json` instead of
/// keeping a "current" pointer, so there is no second source of truth to disagree with the
/// files; a later refresh is simply newer again.
public struct IndexSnapshotStore: Sendable {
    public static let keep = 12
    static let rolledBackSuffix = ".rolledback.json"
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Every snapshot file, oldest first. Anything whose name is not a canonical stamp
    /// (`config.json`, a hand-made `2026-10-04.json`) is not a snapshot and is never touched.
    public func list() -> [SnapshotRef] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> SnapshotRef? in
            let rolled = name.hasSuffix(Self.rolledBackSuffix)
            let stem: String
            if rolled { stem = String(name.dropLast(Self.rolledBackSuffix.count)) }
            else if name.hasSuffix(".json") { stem = String(name.dropLast(5)) }
            else { return nil }
            guard let date = IndexStamp.date(stem) else { return nil }
            return SnapshotRef(url: directory.appendingPathComponent(name), stamp: stem, date: date, rolledBack: rolled)
        }.sorted { $0.stamp < $1.stamp }
    }

    /// Nil for a file that does not decode (a torn write) or that a newer Flight Deck wrote —
    /// either way it is skipped, never half-read.
    public func load(_ ref: SnapshotRef) -> IndexSnapshot? {
        guard let data = try? Data(contentsOf: ref.url),
              let snapshot = try? IndexSnapshot.decoder().decode(IndexSnapshot.self, from: data),
              snapshot.v <= IndexSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public func current() -> (ref: SnapshotRef, snapshot: IndexSnapshot)? {
        for ref in list().reversed() where !ref.rolledBack {
            if let s = load(ref) { return (ref, s) }
        }
        return nil
    }

    public func previous(before ref: SnapshotRef) -> (ref: SnapshotRef, snapshot: IndexSnapshot)? {
        for r in list().reversed() where !r.rolledBack && r.stamp < ref.stamp {
            if let s = load(r) { return (r, s) }
        }
        return nil
    }

    /// Writes `snapshot` under a stamp strictly newer than every existing file. Usually that is
    /// its `createdAt`; when the clock has moved back, or a second write lands in the same
    /// second, it is one second past the newest — a new snapshot must become current, and a
    /// stamp that sorted older would silently leave the previous one in charge.
    @discardableResult
    public func write(_ snapshot: IndexSnapshot) throws -> SnapshotRef {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var date = snapshot.createdAt
        if let newest = list().last, IndexStamp.string(date) <= newest.stamp {
            date = newest.date.addingTimeInterval(1)
        }
        let stamp = IndexStamp.string(date)
        let url = directory.appendingPathComponent(stamp + ".json")
        try IndexSnapshot.encoder().encode(snapshot).write(to: url, options: .atomic)
        return SnapshotRef(url: url, stamp: stamp, date: IndexStamp.date(stamp) ?? date, rolledBack: false)
    }

    /// Makes the previous valid snapshot current by renaming the current one aside. Throws, and
    /// changes nothing, when there is no earlier valid snapshot.
    @discardableResult
    public func rollBack() throws -> (ref: SnapshotRef, snapshot: IndexSnapshot) {
        guard let cur = current(), let prev = previous(before: cur.ref) else { throw IndexStoreError.nothingToRollBackTo }
        try FileManager.default.moveItem(at: cur.ref.url,
                                         to: directory.appendingPathComponent(cur.ref.stamp + Self.rolledBackSuffix))
        return prev
    }

    /// Keeps the newest `keep` valid snapshots and deletes every snapshot file — valid, corrupt
    /// or rolled back — older than the oldest one kept. Counting only VALID ones means a run of
    /// torn writes can never push the last good snapshots out.
    public func prune(keep: Int = IndexSnapshotStore.keep) throws {
        let all = list()
        let valid = all.filter { !$0.rolledBack && load($0) != nil }
        guard let oldestKept = valid.suffix(keep).first?.stamp else { return }
        for ref in all where ref.stamp < oldestKept {
            try FileManager.default.removeItem(at: ref.url)
        }
    }
}

/// One model × dimension that moved between two snapshots. `before` nil: it appeared;
/// `after` nil: it went unknown.
public struct ScoreChange: Equatable, Sendable {
    public var model: ModelRef
    public var dimension: String
    public var before: Double?
    public var after: Double?
    public init(model: ModelRef, dimension: String, before: Double?, after: Double?) {
        self.model = model; self.dimension = dimension; self.before = before; self.after = after
    }
    public var delta: Double? {
        guard let before, let after else { return nil }
        return after - before
    }
}

public enum SnapshotDiff {
    /// What Settings shows above Roll back: every computed score that moved by at least
    /// `minimumChange`, appeared or disappeared — largest movement first (an appearance or a
    /// disappearance counts as 1), then by model key and dimension.
    public static func changes(from old: IndexSnapshot?, to new: IndexSnapshot, minimumChange: Double = 0.01) -> [ScoreChange] {
        guard let old else { return [] }
        func table(_ s: IndexSnapshot) -> [String: (model: ModelRef, scores: [String: Double])] {
            var out: [String: (model: ModelRef, scores: [String: Double])] = [:]
            for m in s.scores { out[IndexKeys.key(m.model)] = (m.model, m.dimensions.mapValues(\.score)) }
            return out
        }
        let before = table(old), after = table(new)
        var out: [ScoreChange] = []
        for key in Set(before.keys).union(after.keys).sorted() {
            guard let model = after[key]?.model ?? before[key]?.model else { continue }
            let b = before[key]?.scores ?? [:], a = after[key]?.scores ?? [:]
            for d in Set(b.keys).union(a.keys).sorted() {
                let change = ScoreChange(model: model, dimension: d, before: b[d], after: a[d])
                if let delta = change.delta, abs(delta) < minimumChange { continue }
                out.append(change)
            }
        }
        return out.sorted { lhs, rhs in
            let l = abs(lhs.delta ?? 1), r = abs(rhs.delta ?? 1)
            if l != r { return l > r }
            return (IndexKeys.key(lhs.model), lhs.dimension) < (IndexKeys.key(rhs.model), rhs.dimension)
        }
    }
}
