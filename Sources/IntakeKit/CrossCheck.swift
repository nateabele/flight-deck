import Foundation

/// `checkpoints/<n>/crosscheck.json` for a cross-check Refine round (coverage spec §4.1): who
/// proposed each entry of that checkpoint's `changes.json`, which family each proposer was as it
/// actually ran, and the integrator's issue clusters. Written only when both reviewers returned,
/// so its absence means "not a cross-check", never "found nothing".
public struct CrossCheckRecord: Codable, Equatable, Sendable {
    public static let fileName = "crosscheck.json"
    /// Per change, 0 = the primary reviewer, 1 = the cross-reviewer.
    public var proposers: [Int]
    /// The family of proposer 0 and of proposer 1. Equal when the primary fell back to the
    /// cross-reviewer's family, which the fold reports as not independent.
    public var families: [AgentID]
    /// Cleaned (`IssueClusters.clean`); nil when the integrator gave none usable.
    public var clusters: [[Int]]?
    public var blindOrderSeed: Int
    public init(proposers: [Int], families: [AgentID], clusters: [[Int]]?, blindOrderSeed: Int) {
        self.proposers = proposers; self.families = families; self.clusters = clusters
        self.blindOrderSeed = blindOrderSeed
    }
}

/// The order the integrator sees a cross-check's proposals in. Blind because the integrator is
/// usually Claude, one reviewer's own family: grouped by proposer, its verdicts could favour its
/// own family, and every per-family number would inherit that. Seeded (by checkpoint id), not
/// random, so a retried round hands the integrator exactly the same list.
public enum BlindOrder {
    public static func interleave(_ a: [ProposedChange], _ b: [ProposedChange], seed: Int)
        -> (changes: [ProposedChange], proposers: [Int]) {
        var tagged = a.map { ($0, 0) } + b.map { ($0, 1) }
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
        // Fisher–Yates with our own generator: `shuffle(using:)` with a seeded RNG is stable across
        // runs, `shuffled()` is not.
        if tagged.count > 1 {
            for i in stride(from: tagged.count - 1, to: 0, by: -1) {
                tagged.swapAt(i, Int(rng.next() % UInt64(i + 1)))
            }
        }
        return (tagged.map(\.0), tagged.map(\.1))
    }

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// The integrator's "these proposals are one issue" groups, held to a partition.
public enum IssueClusters {
    /// Indices outside `0..<count` dropped, an index already placed dropped, members sorted,
    /// clusters left with fewer than 2 members dropped (singletons are implicit); nil when nothing
    /// is left. The same forgiving cleaning `IntegrateOutput.verdicts(forChanges:)` does: a
    /// malformed grouping is worth less, not worth pausing a round over.
    public static func clean(_ raw: [[Int]]?, count: Int) -> [[Int]]? {
        guard let raw else { return nil }
        var placed = Set<Int>()
        let out = raw.compactMap { cluster -> [Int]? in
            let members = Array(Set(cluster)).sorted().filter { (0..<count).contains($0) && !placed.contains($0) }
            guard members.count >= 2 else { return nil }
            placed.formUnion(members)
            return members
        }
        return out.isEmpty ? nil : out
    }

    /// Every index in exactly one group: the clusters, then each unclustered index alone.
    public static func partition(_ clusters: [[Int]]?, count: Int) -> [[Int]] {
        let groups = clusters ?? []
        let placed = Set(groups.flatMap { $0 })
        return groups + (0..<count).filter { !placed.contains($0) }.map { [$0] }
    }
}
