import Foundation

// Coverage: how much of a plan's issue space two independent reviewers have searched, estimated
// from a cross-check round by capture–recapture (coverage spec §5). Like convergence, every
// number is a signal: the estimate assumes independent reviewers, and two model families are
// only partly independent — correlated reviewers make it read LOW, which is why a near-total
// overlap is flagged rather than trusted.

public enum CoverageBand: String, Equatable, Sendable { case saturated, fewLeft, manyLeft, noOverlap, sameFamily, unmeasured }
public enum CoverageMatcher: String, Equatable, Sendable { case integrator, textSimilarity }

/// Placeholders, not measurements: no real Refine tape existed to fit them against when they were
/// chosen (2026-09-29, one intake on disk, stopped before Refine 1). Tune them from finished tapes.
public struct CoverageThresholds: Equatable, Sendable {
    /// Two independent searches that between them found at most this many accepted issues: the
    /// small sample is itself the answer.
    public var saturatedFound = 2
    public var saturatedUnfound = 2
    public var fewUnfound = 6
    /// Correlated: the smaller family found at least this many, and this share of them overlap.
    public var correlatedMin = 5
    public var correlatedShare = 0.9
    /// The integrator's and the text matcher's overlap differ by at least this many AND this share.
    public var matcherGap = 5
    public var matcherShare = 0.5
    public static let `default` = CoverageThresholds()
    public init() {}
}

public struct CoverageReading: Equatable, Sendable {
    public var checkpoint: Int
    public var round: Int
    public var familyA: ModelFamily
    public var familyB: ModelFamily
    public var matcher: CoverageMatcher
    /// Accepted issues (a cluster with any agree/somewhat member) raised by A, by B, by both.
    public var n1: Int
    public var n2: Int
    public var both: Int
    /// Proposals the integrator disagreed with, per family: precision, not coverage.
    public var rejectedA: Int
    public var rejectedB: Int
    public var found: Int
    /// Chapman's estimate minus what was found; nil when there is no estimate (same family, unmeasured).
    public var unfound: Int?
    public var band: CoverageBand
    public var correlated: Bool
    /// The text matcher's `both`, computed beside the integrator's as a sanity check.
    public var textSimilarityBoth: Int?
    public var matchersDisagree: Bool

    public init(checkpoint: Int, round: Int, familyA: ModelFamily, familyB: ModelFamily, matcher: CoverageMatcher,
                n1: Int, n2: Int, both: Int, rejectedA: Int, rejectedB: Int, found: Int, unfound: Int?,
                band: CoverageBand, correlated: Bool, textSimilarityBoth: Int?, matchersDisagree: Bool) {
        self.checkpoint = checkpoint
        self.round = round
        self.familyA = familyA
        self.familyB = familyB
        self.matcher = matcher
        self.n1 = n1
        self.n2 = n2
        self.both = both
        self.rejectedA = rejectedA
        self.rejectedB = rejectedB
        self.found = found
        self.unfound = unfound
        self.band = band
        self.correlated = correlated
        self.textSimilarityBoth = textSimilarityBoth
        self.matchersDisagree = matchersDisagree
    }
}

public enum CoverageSeries {
    /// Chapman's bias-corrected Lincoln–Petersen: finite at no overlap, less biased on small samples.
    public static func chapman(n1: Int, n2: Int, both: Int) -> Double {
        Double((n1 + 1) * (n2 + 1)) / Double(both + 1) - 1
    }

    /// One reading per Refine checkpoint with a `crosscheck.json`, oldest first.
    public static func readings(_ checkpoints: [Checkpoint], loadFile: (Int, String) -> Data?,
                                thresholds: CoverageThresholds = .default) -> [CoverageReading] {
        checkpoints.filter { $0.stage == .refine }.compactMap { cp in
            guard let record = loadFile(cp.id, CrossCheckRecord.fileName)
                .flatMap({ try? IntakeJSON.decoder.decode(CrossCheckRecord.self, from: $0) }) else { return nil }
            let changes = loadFile(cp.id, "changes.json").flatMap { try? IntakeJSON.decoder.decode([ProposedChange].self, from: $0) }
            let verdicts = loadFile(cp.id, "verdicts.json").flatMap { try? IntakeJSON.decoder.decode([ChangeVerdict].self, from: $0) }
            return reading(checkpoint: cp.id, round: cp.round, record: record, changes: changes, verdicts: verdicts,
                           thresholds: thresholds)
        }
    }

    public static func reading(checkpoint: Int, round: Int, record: CrossCheckRecord, changes: [ProposedChange]?,
                               verdicts: [ChangeVerdict]?, thresholds t: CoverageThresholds = .default) -> CoverageReading {
        let count = record.proposers.count
        let a = record.families.first ?? .codex, b = record.families.dropFirst().first ?? a
        let textClusters = changes.flatMap { $0.count == count ? ConvergenceSeries.textClusters($0) : nil }
        let matcher: CoverageMatcher = record.clusters == nil ? .textSimilarity : .integrator
        let clusters = record.clusters ?? textClusters
        var out = CoverageReading(checkpoint: checkpoint, round: round, familyA: a, familyB: b, matcher: matcher,
                                  n1: 0, n2: 0, both: 0, rejectedA: 0, rejectedB: 0, found: 0, unfound: nil,
                                  band: .unmeasured, correlated: false, textSimilarityBoth: nil, matchersDisagree: false)
        // Accepted issues can't be counted without per-change verdicts: unmeasured, never 0.
        guard let verdicts else { return out }
        let verdict = Dictionary(verdicts.map { ($0.index, $0.verdict) }, uniquingKeysWith: { first, _ in first })
        func counts(_ clusters: [[Int]]?) -> (n1: Int, n2: Int, both: Int) {
            var n1 = 0, n2 = 0, both = 0
            for issue in IssueClusters.partition(clusters, count: count) {
                guard issue.contains(where: { verdict[$0] == .agree || verdict[$0] == .somewhat }) else { continue }
                let byA = issue.contains { record.proposers[$0] == 0 }, byB = issue.contains { record.proposers[$0] == 1 }
                if byA { n1 += 1 }
                if byB { n2 += 1 }
                if byA && byB { both += 1 }
            }
            return (n1, n2, both)
        }
        (out.n1, out.n2, out.both) = counts(clusters)
        out.rejectedA = (0..<count).filter { record.proposers[$0] == 0 && verdict[$0] == .disagree }.count
        out.rejectedB = (0..<count).filter { record.proposers[$0] == 1 && verdict[$0] == .disagree }.count
        out.found = out.n1 + out.n2 - out.both
        if matcher == .integrator, changes?.count == count {
            let text = counts(textClusters).both
            out.textSimilarityBoth = text
            let gap = abs(text - out.both)
            out.matchersDisagree = gap >= t.matcherGap && Double(gap) >= t.matcherShare * Double(max(text, out.both))
        }
        let smaller = min(out.n1, out.n2)
        out.correlated = smaller >= t.correlatedMin && Double(out.both) / Double(smaller) >= t.correlatedShare
        guard a != b else { out.band = .sameFamily; return out }
        out.unfound = max(0, Int((chapman(n1: out.n1, n2: out.n2, both: out.both) - Double(out.found)).rounded()))
        if out.found <= t.saturatedFound {
            out.band = .saturated
        } else if out.both == 0 {
            out.band = .noOverlap
        } else if out.unfound! <= t.saturatedUnfound {
            out.band = .saturated
        } else if out.unfound! <= t.fewUnfound {
            out.band = .fewLeft
        } else {
            out.band = .manyLeft
        }
        return out
    }
}
