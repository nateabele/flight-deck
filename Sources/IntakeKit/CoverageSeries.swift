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
        // `record.clusters` came off disk (`crosscheck.json`): a corrupted or hand-edited file, or
        // version skew, can carry an out-of-range or repeated index. Clean it before it ever
        // reaches `partition`, exactly as `ConvergenceSeries.point` must (same file, same risk).
        // A record whose clusters clean to nothing reads as none given, same as no clusters at all.
        let cleanedClusters = IssueClusters.clean(record.clusters, count: count)
        let matcher: CoverageMatcher = cleanedClusters == nil ? .textSimilarity : .integrator
        let clusters = cleanedClusters ?? textClusters
        var out = CoverageReading(checkpoint: checkpoint, round: round, familyA: a, familyB: b, matcher: matcher,
                                  n1: 0, n2: 0, both: 0, rejectedA: 0, rejectedB: 0, found: 0, unfound: nil,
                                  band: .unmeasured, correlated: false, textSimilarityBoth: nil, matchersDisagree: false)
        // Accepted issues can't be counted without per-change verdicts: unmeasured, never 0.
        guard let verdicts else { return out }
        let verdict = Dictionary(verdicts.map { ($0.index, $0.verdict) }, uniquingKeysWith: { first, _ in first })
        // Bounds-checked rather than a bare subscript: cleaning already keeps every index here
        // inside `0..<count`, but a malformed record must never trap this fold regardless — it
        // runs off-main in the live app. A value that is neither 0 nor 1 reads as neither family.
        func proposer(_ i: Int) -> Int? { record.proposers.indices.contains(i) ? record.proposers[i] : nil }
        func counts(_ clusters: [[Int]]?) -> (n1: Int, n2: Int, both: Int) {
            var n1 = 0, n2 = 0, both = 0
            for issue in IssueClusters.partition(clusters, count: count) {
                guard issue.contains(where: { verdict[$0] == .agree || verdict[$0] == .somewhat }) else { continue }
                let byA = issue.contains { proposer($0) == 0 }, byB = issue.contains { proposer($0) == 1 }
                if byA { n1 += 1 }
                if byB { n2 += 1 }
                if byA && byB { both += 1 }
            }
            return (n1, n2, both)
        }
        (out.n1, out.n2, out.both) = counts(clusters)
        out.rejectedA = (0..<count).filter { proposer($0) == 0 && verdict[$0] == .disagree }.count
        out.rejectedB = (0..<count).filter { proposer($0) == 1 && verdict[$0] == .disagree }.count
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

/// Each fidelity's cross-check target (spec §7): what "enough coverage" means for that preset,
/// and how to tell a reading against it. A customized config keeps its preset's target — the
/// target tracks what was chosen at intake, not the drafter/reviewer counts a human tuned after.
public enum CoverageTarget: Equatable, Sendable {
    case none
    case fewLeftOrBetter
    case saturatedIndependent

    public init(_ preset: Preset) {
        switch preset {
        case .bead, .sketch: self = .none
        case .featurePlan: self = .fewLeftOrBetter
        case .fullPlan: self = .saturatedIndependent
        }
    }

    public var label: String? {
        switch self {
        case .none: nil
        case .fewLeftOrBetter: "FEW LEFT or better"
        case .saturatedIndependent: "SATURATED, independent"
        }
    }

    /// nil when there's nothing to judge: no target (`.none`), or a reading that can't speak to
    /// coverage at all (same family, unmeasured).
    public func met(by reading: CoverageReading) -> Bool? {
        guard self != .none, reading.band != .sameFamily, reading.band != .unmeasured else { return nil }
        switch self {
        case .none:
            return nil
        case .fewLeftOrBetter:
            return reading.band == .saturated || reading.band == .fewLeft
        case .saturatedIndependent:
            return reading.band == .saturated && !reading.correlated
        }
    }
}

public enum CoverageState: Equatable, Sendable {
    /// No cross-check reading yet: no Refine round has run, or none of them cross-checked.
    case awaiting
    case reading(CoverageBand)
    /// Converged (or plateaued) short of the target, with no round left that would re-measure it.
    case stalled
}

public struct CoverageVerdict: Equatable, Sendable {
    public var state: CoverageState
    public var latest: CoverageReading?
    public var target: CoverageTarget
    public var targetMet: Bool?
    public var suggestedAction: String
    public var failedCrossCheckRound: Int?

    public init(state: CoverageState, latest: CoverageReading?, target: CoverageTarget, targetMet: Bool?,
                suggestedAction: String, failedCrossCheckRound: Int?) {
        self.state = state
        self.latest = latest
        self.target = target
        self.targetMet = targetMet
        self.suggestedAction = suggestedAction
        self.failedCrossCheckRound = failedCrossCheckRound
    }
}

extension CoverageSeries {
    /// "<Preset>" spelled for the suggestion strings. IntakeKit can't see `UIText.presetName`
    /// (it lives in the app target) — this mirrors its copy; keep the two in sync by hand.
    private static func name(_ preset: Preset) -> String {
        switch preset {
        case .bead: "Single task"
        case .sketch: "Sketch"
        case .featurePlan: "Feature plan"
        case .fullPlan: "Full plan"
        }
    }

    /// The stopping signal (spec §7): is coverage enough for this fidelity, and if not, what to
    /// do about it. `readings` is oldest first, `refineRoundsRemaining` counts the rounds the
    /// planner would still run — both drive the "already saturated, stop early" suggestion.
    public static func verdict(readings: [CoverageReading], preset: Preset, convergence: ConvergenceVerdict?,
                               refineRoundsRemaining: Int, failedCrossCheckRound: Int?) -> CoverageVerdict {
        let target = CoverageTarget(preset)
        let latest = readings.last
        let targetMet = latest.flatMap(target.met)
        let stalled: Bool
        switch convergence {
        case .converging(settled: true), .plateau: stalled = targetMet == false
        default: stalled = false
        }
        let state: CoverageState = latest == nil ? .awaiting : (stalled ? .stalled : .reading(latest!.band))
        let action = suggestedAction(latest: latest, preset: preset, target: target, targetMet: targetMet,
                                     stalled: stalled, refineRoundsRemaining: refineRoundsRemaining,
                                     failedCrossCheckRound: failedCrossCheckRound)
        return CoverageVerdict(state: state, latest: latest, target: target, targetMet: targetMet,
                               suggestedAction: action, failedCrossCheckRound: failedCrossCheckRound)
    }

    /// Table order from spec §7 — the first row whose condition holds wins.
    private static func suggestedAction(latest: CoverageReading?, preset: Preset, target: CoverageTarget,
                                        targetMet: Bool?, stalled: Bool, refineRoundsRemaining: Int,
                                        failedCrossCheckRound: Int?) -> String {
        if stalled {
            return "Stalled: converged, but coverage is short of the \(name(preset)) target. One more Refine round "
                + "will cross-check again; if it stays short, the plan may need a third model family."
        }
        if let latest, latest.round == 1, targetMet == true, refineRoundsRemaining >= 2 {
            return "Saturated at Refine 1. Consider removing the remaining \(refineRoundsRemaining) Refine rounds "
                + "(Run ▸ Remove a Round, ⌘-)."
        }
        if let latest, latest.band == .noOverlap || latest.band == .manyLeft {
            return "Coverage is short. \(latest.familyA.displayName) and \(latest.familyB.displayName) are finding "
                + "different issues; another round, or a higher fidelity, would search more."
        }
        if let latest, latest.correlated {
            return "\(latest.familyA.displayName) and \(latest.familyB.displayName) found nearly the same issues. "
                + "The estimate may be low; similar models share blind spots."
        }
        if let latest, latest.band == .sameFamily {
            return "Both reviews at Refine \(latest.round) ran as \(latest.familyA.displayName), so coverage is unmeasured there."
        }
        if let failedCrossCheckRound, failedCrossCheckRound > (latest?.round ?? 0) {
            return "The cross-check agent failed at Refine \(failedCrossCheckRound), so coverage is unmeasured there."
        }
        return ""
    }
}
