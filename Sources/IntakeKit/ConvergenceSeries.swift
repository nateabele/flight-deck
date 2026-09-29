import Foundation

// Convergence: whether each fresh Refine (or Polish) round's suggestions are getting smaller and
// more like the last round's, the methodology's "very incremental" steady state. That is a
// human judgement, and every number here is a signal, not a promise. Reviewers stop at a fixed
// issue budget, and models differ in granularity by 5x or more, so there is deliberately no
// "percent converged": only a verdict, the numbers behind it, and what to do next.

/// One Refine or Polish round's convergence inputs, folded from its checkpoint, its stored
/// proposals and verdicts, and its plan against the plan the round started from.
public struct ConvergencePoint: Equatable, Sendable {
    public var checkpoint: Int
    public var stage: Stage
    public var round: Int
    /// Proposed changes (refine) or ops changed (polish). Never compared across stages.
    public var changeCount: Int
    /// Plan lines added + removed (0 for polish, which does not edit the plan).
    public var linesChurned: Int
    /// Polish only: the dependency-edge share of `changeCount`.
    public var edgesChanged: Int?
    /// (agree + ½·somewhat) / verdicts given; nil with no tally (polish, a round that
    /// proposed nothing, or an integrator that gave no verdicts).
    public var agreeRatio: Double?
    public var sectionsTouched: [String]
    /// Heading → lines changed; empty when either plan is unavailable.
    public var sectionChurn: [String: Int]
    /// The reviewer's (refine) or polisher's model, as it actually ran.
    public var reviewerModel: ModelChoice?
    /// Proposals that repeat one from an earlier round of this cycle; nil when this round's
    /// `changes.json` is not on disk.
    public var repeatCount: Int?
    /// Proposals that repeat one the integrator disagreed with; nil when this round's
    /// `changes.json` is missing, or no earlier round of the cycle kept its verdicts.
    public var reopenCount: Int?
    /// Sections where this round removed most of what an earlier round of the cycle added.
    public var reopenedSections: [String]
    /// Reviewed by two families; `changeCount` is its deduplicated issue count, the closest to
    /// one reviewer's. Drawn hollow so it reads as measured differently.
    public var crossCheck: Bool

    public init(checkpoint: Int, stage: Stage, round: Int, changeCount: Int, linesChurned: Int,
                edgesChanged: Int? = nil, agreeRatio: Double? = nil, sectionsTouched: [String] = [],
                sectionChurn: [String: Int] = [:], reviewerModel: ModelChoice? = nil, repeatCount: Int? = nil,
                reopenCount: Int? = nil, reopenedSections: [String] = [], crossCheck: Bool = false) {
        self.checkpoint = checkpoint; self.stage = stage; self.round = round
        self.changeCount = changeCount; self.linesChurned = linesChurned; self.edgesChanged = edgesChanged
        self.agreeRatio = agreeRatio; self.sectionsTouched = sectionsTouched; self.sectionChurn = sectionChurn
        self.reviewerModel = reviewerModel; self.repeatCount = repeatCount; self.reopenCount = reopenCount
        self.reopenedSections = reopenedSections; self.crossCheck = crossCheck
    }
}

/// The numbers a verdict is read from. The ratio, delta and slope cover the compared rounds only
/// (from `restartRound` on when the reviewer's model changed). The section signals cover the
/// whole cycle, because a section that keeps moving is a problem whoever moves it.
public struct ConvergenceTrend: Equatable, Sendable {
    /// last / previous changeCount; nil with fewer than 2 compared rounds or a previous 0.
    public var changeRatio: Double?
    /// last − previous agreeRatio.
    public var agreeDelta: Double?
    /// Least-squares slope of ln(changeCount + 1) per round; below 0 is decaying.
    public var logSlope: Double?
    /// Changed in each of the last `hotRuns` rounds, not shrinking, and at least `hotShare`
    /// of the last round's churn: the methodology's oscillation red flag.
    public var hotSection: String?
    /// Reopened (see `ConvergencePoint.reopenedSections`) in at least `reopenRuns` rounds,
    /// the last one included.
    public var reopenedSection: String?
    /// The reviewer/polisher model differs within the cycle.
    public var modelChanged: Bool
    /// The round the trend restarts from after the last model change.
    public var restartRound: Int?

    public init(changeRatio: Double? = nil, agreeDelta: Double? = nil, logSlope: Double? = nil,
                hotSection: String? = nil, reopenedSection: String? = nil, modelChanged: Bool = false,
                restartRound: Int? = nil) {
        self.changeRatio = changeRatio; self.agreeDelta = agreeDelta; self.logSlope = logSlope
        self.hotSection = hotSection; self.reopenedSection = reopenedSection
        self.modelChanged = modelChanged; self.restartRound = restartRound
    }
}

public enum ConvergenceVerdict: Equatable, Sendable {
    /// Fewer than 2 rounds to compare.
    case tooEarly
    case converging(settled: Bool)
    case plateau
    case diverging(reason: DivergenceReason)
}

public enum DivergenceReason: Equatable, Sendable {
    /// changeCount up at least `growRatio` and by at least `growMin`: the "expansion" red flag.
    case growing
    /// agreeRatio down at least `agreeDrop`.
    case agreementFell
    /// The heading of a section that keeps changing (`ConvergenceTrend.hotSection`).
    case hotSection(String)
    /// The heading of a section that keeps being put back (`ConvergenceTrend.reopenedSection`).
    case reopened(String)
}

/// These thresholds are a starting point, not measurements. The methodology's own weighted
/// score (0.75 / 0.90) is labelled illustrative, and none of these have been fitted to real
/// tapes yet. Tune them once there are enough recorded cycles to check them against.
public struct ConvergenceThresholds: Equatable, Sendable {
    /// Converging: the last count is at most 60% of the previous one.
    public var convergingRatio = 0.6
    /// Converging may not lose more than 5 points of agreement.
    public var agreeTolerance = 0.05
    /// Settled: changeCount ≤ max(settledFloor, settledFraction × the first compared round),
    /// with agreement ≥ settledAgree when there is any.
    public var settledFloor = 5
    public var settledFraction = 0.15
    public var settledAgree = 0.85
    /// Diverging (growing): last ≥ growRatio × previous and last − previous ≥ growMin.
    public var growRatio = 1.25
    public var growMin = 3
    /// Diverging (agreementFell): agreement down by at least this much.
    public var agreeDrop = 0.15
    /// Hot section: at least this share of the last round's churn, over the last hotRuns rounds.
    public var hotShare = 0.3
    public var hotRuns = 3
    /// Reopened section: this round removed at least this share of an earlier round's added
    /// lines in the section, in at least reopenRuns rounds.
    public var reversalShare = 0.6
    public var reopenRuns = 2
    /// Repeat: word-set Jaccard at or above wordOverlap, or word-3-shingle Jaccard at or above
    /// shingleOverlap, in the same section.
    public var wordOverlap = 0.5
    public var shingleOverlap = 0.35
    public static let `default` = ConvergenceThresholds()
    public init() {}
}

/// Consecutive rounds of one stage: Refine 1…N (extensions included), or Polish 1…M.
public struct ConvergenceCycle: Equatable, Sendable {
    public var stage: Stage
    public var points: [ConvergencePoint]
    public var trend: ConvergenceTrend
    public var verdict: ConvergenceVerdict
    /// One line of numbers, such as "41 → 14 → 5 changes · agreement 70% → 90% · settled".
    public var explanation: String
    /// What to do about it. Empty while it is too early to say.
    public var suggestedAction: String
}

public enum ConvergenceSeries {
    /// Every Refine and Polish cycle on the tape, in order. `loadFile(checkpoint, relativePath)`
    /// reads a checkpoint's files: `plan.md`, `plan.user.md`, `drafts/<i>.md`, `changes.json`,
    /// `verdicts.json`. A missing file only drops the signals it feeds.
    ///
    /// Draft, synthesis, encode, fresh-eyes and dedup never enter a series: each runs once, and
    /// encode's `changeCount` is `ops.count`, a different unit from polish's ops changed.
    public static func cycles(_ checkpoints: [Checkpoint], loadFile: (Int, String) -> Data?,
                              thresholds: ConvergenceThresholds = .default) -> [ConvergenceCycle] {
        let plans = planPairs(checkpoints, loadFile: loadFile)
        var runs: [[Checkpoint]] = []
        var previous: Checkpoint?
        for cp in checkpoints {
            defer { previous = cp }
            guard cp.stage == .refine || cp.stage == .polish else { continue }
            // Consecutive on the tape, not just the same stage: anything in between ends the run.
            if previous?.stage == cp.stage, !runs.isEmpty { runs[runs.count - 1].append(cp) } else { runs.append([cp]) }
        }
        return runs.map { run in
            let proposals = run.map { cp in
                (changes: loadFile(cp.id, "changes.json").flatMap { try? IntakeJSON.decoder.decode([ProposedChange].self, from: $0) },
                 verdicts: loadFile(cp.id, "verdicts.json").flatMap { try? IntakeJSON.decoder.decode([ChangeVerdict].self, from: $0) })
            }
            // Absence means "not a cross-check" (CrossCheckRecord's doc comment), so a plain
            // round's checkpoint just never has this file.
            let crossChecks = run.map { cp in
                loadFile(cp.id, CrossCheckRecord.fileName).flatMap { try? IntakeJSON.decoder.decode(CrossCheckRecord.self, from: $0) }
            }
            let edits = run.map { cp in plans[cp.id].map { sectionEdits(from: $0.base, to: $0.plan) } }
            let points = run.indices.map { i in
                point(run[i], plans: plans[run[i].id], proposals: proposals, edits: edits, at: i, thresholds,
                     cross: crossChecks[i])
            }
            return assess(run[0].stage, points, thresholds: thresholds)
        }
    }

    /// Lines changed per `#` section for every checkpoint, against the effective plan of the
    /// plan checkpoint before it: the plan that round actually started from, the human's edit
    /// included, so an edit is never counted as the round's churn. A checkpoint is absent
    /// when either plan is unavailable.
    public static func sectionChurn(_ checkpoints: [Checkpoint], loadFile: (Int, String) -> Data?) -> [Int: [String: Int]] {
        planPairs(checkpoints, loadFile: loadFile).mapValues { PlanMetrics.sectionChurn(from: $0.base, to: $0.plan) }
    }

    /// The trend, verdict and words for one cycle's points.
    public static func assess(_ stage: Stage, _ points: [ConvergencePoint],
                              thresholds t: ConvergenceThresholds = .default) -> ConvergenceCycle {
        let trend = trend(points, t)
        let verdict = verdict(points, trend, t)
        return ConvergenceCycle(stage: stage, points: points, trend: trend, verdict: verdict,
                                explanation: explanation(stage, points, trend, verdict),
                                suggestedAction: suggestedAction(stage, points, verdict))
    }

    // MARK: - Points

    private static func point(_ cp: Checkpoint, plans: (base: String, plan: String)?,
                              proposals: [(changes: [ProposedChange]?, verdicts: [ChangeVerdict]?)],
                              edits: [SectionEdits?], at i: Int, _ t: ConvergenceThresholds,
                              cross: CrossCheckRecord?) -> ConvergencePoint {
        let r = cp.record
        let role = cp.stage == .refine ? "reviewer" : "polisher"
        let (repeats, reopens) = repeatsAndReopens(proposals, at: i, t)
        // A cross-check round proposed from two families; counting every proposal would spike the
        // series on exactly the rounds that measure coverage (coverage spec §6).
        let issues: Int? = cross.map { record in
            let clusters = record.clusters ?? proposals[i].changes.flatMap { Self.textClusters($0, thresholds: t) }
            return IssueClusters.partition(clusters, count: record.proposers.count).count
        }
        return ConvergencePoint(
            checkpoint: cp.id, stage: cp.stage, round: cp.round, changeCount: issues ?? r.changeCount ?? 0,
            linesChurned: r.linesAdded + r.linesRemoved, edgesChanged: r.edgesChanged,
            agreeRatio: r.tally.flatMap(agreeRatio), sectionsTouched: r.sectionsChanged,
            sectionChurn: plans.map { PlanMetrics.sectionChurn(from: $0.base, to: $0.plan) } ?? [:],
            reviewerModel: r.slots.last { $0.role == role }?.used, repeatCount: repeats, reopenCount: reopens,
            reopenedSections: reopenedSections(edits, at: i, t), crossCheck: cross != nil)
    }

    /// Over the verdicts actually given, not `changeCount`: the integrator's tally can
    /// disagree with the number of proposals, and a ratio over the wrong denominator would
    /// read a short tally as disagreement.
    private static func agreeRatio(_ tally: VerdictTally) -> Double? {
        let total = tally.agree + tally.somewhat + tally.disagree
        return total == 0 ? nil : (Double(tally.agree) + 0.5 * Double(tally.somewhat)) / Double(total)
    }

    /// Each checkpoint's generated plan paired with the effective plan of the checkpoint before
    /// it. The base is only the IMMEDIATELY preceding checkpoint's plan: when that one is
    /// missing, reaching further back would charge two rounds' churn to this one. Both read
    /// unwrapped (`PlanLayers.readPlan`), so the first round after a checkpoint recorded wrapped
    /// is not charged with reflowing every paragraph of it.
    private static func planPairs(_ checkpoints: [Checkpoint], loadFile: (Int, String) -> Data?) -> [Int: (base: String, plan: String)] {
        func text(_ id: Int, _ path: String) -> String? { loadFile(id, path).map(PlanLayers.readPlan) }
        var pairs: [Int: (base: String, plan: String)] = [:]
        var base: String?
        for cp in checkpoints {
            // A draft checkpoint's plan is its first surviving draft (`PlanLayers.generatedURL`);
            // its record has one slot per drafter, which bounds the search.
            var generated = text(cp.id, PlanLayers.generatedName)
            for i in 0..<max(cp.record.slots.count, 1) where generated == nil { generated = text(cp.id, "drafts/\(i).md") }
            if let base, let generated { pairs[cp.id] = (base, generated) }
            base = text(cp.id, PlanLayers.userName) ?? generated
        }
        return pairs
    }

    // MARK: - Novel vs repeated

    /// A proposal repeats an earlier one in the cycle when both name the same section (after
    /// normalization) and their words overlap. A repeat is a reopen when the earlier one was
    /// `disagree`d. Earlier rounds, not just the previous one: a change rejected in R1 and
    /// re-proposed in R3 is the clearest reopen there is.
    private static func repeatsAndReopens(_ proposals: [(changes: [ProposedChange]?, verdicts: [ChangeVerdict]?)],
                                          at i: Int, _ t: ConvergenceThresholds) -> (Int?, Int?) {
        guard let changes = proposals[i].changes else { return (nil, nil) }
        let earlier = proposals[..<i].compactMap { p in
            p.changes.map { changes in
                (changes: changes.map(Fingerprint.init), verdicts: p.verdicts.map { Dictionary($0.map { ($0.index, $0.verdict) },
                                                                                                uniquingKeysWith: { a, _ in a }) })
            }
        }
        var repeats = 0, reopens = 0
        for change in changes.map(Fingerprint.init) {
            var matched = false, rejected = false
            for round in earlier {
                for (j, old) in round.changes.enumerated() where old.matches(change, t) {
                    matched = true
                    if round.verdicts?[j] == .disagree { rejected = true }
                }
            }
            if matched { repeats += 1 }
            if rejected { reopens += 1 }
        }
        let verdictsKnown = i == 0 || earlier.contains { $0.verdicts != nil }
        return (repeats, verdictsKnown ? reopens : nil)
    }

    /// The same "same idea" test `repeatCount` uses, never checked against human judgement: the
    /// fallback when the integrator gave no clusters, and the sanity check beside them. Groups
    /// transitively — `matches` is not itself transitive, so A~B and B~C puts all three in one
    /// cluster even where A and C alone wouldn't match.
    public static func textClusters(_ changes: [ProposedChange], thresholds t: ConvergenceThresholds = .default) -> [[Int]]? {
        let prints = changes.map(Fingerprint.init)
        var parent = Array(prints.indices)
        func find(_ x: Int) -> Int {
            if parent[x] != x { parent[x] = find(parent[x]) }
            return parent[x]
        }
        for i in prints.indices {
            for j in (i + 1)..<prints.count where prints[i].matches(prints[j], t) {
                let (ri, rj) = (find(i), find(j))
                if ri != rj { parent[ri] = rj }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in prints.indices { groups[find(i), default: []].append(i) }
        let clusters = groups.values.filter { $0.count >= 2 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
        return clusters.isEmpty ? nil : clusters
    }

    /// A proposal reduced to what "the same idea" is judged on, embedding-free: lowercased,
    /// markdown/diff markers and punctuation gone, stop words dropped, crudely stemmed, then
    /// the word set and its word 3-shingles. The section is compared on its own and kept out of
    /// the word set: it must match anyway, and two unrelated changes to one section would
    /// otherwise share its words.
    private struct Fingerprint {
        var section: [String]
        var words: Set<String>
        var shingles: Set<[String]>

        init(_ change: ProposedChange) {
            section = Self.tokens(change.section)
            let body = Self.tokens(change.rationale + " " + change.edit)
            words = Set(body)
            shingles = body.count < 3 ? [] : Set((0...(body.count - 3)).map { Array(body[$0..<$0 + 3]) })
        }

        func matches(_ other: Fingerprint, _ t: ConvergenceThresholds) -> Bool {
            section == other.section
                && (jaccard(words, other.words) >= t.wordOverlap || jaccard(shingles, other.shingles) >= t.shingleOverlap)
        }

        private static let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "into", "is", "it", "its", "of",
            "on", "or", "so", "that", "the", "this", "to", "was", "we", "with",
        ]

        static func tokens(_ text: String) -> [String] {
            let cleaned = String(text.lowercased().unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
            })
            return cleaned.split(separator: " ").map(String.init).filter { !stopWords.contains($0) }.map(stem)
        }

        /// Trailing -ing/-ed/-es/-s, then a trailing -e, so "enable"/"enabled"/"enables" and
        /// "feature"/"features" meet. Crude on purpose: overlap, not linguistics.
        private static func stem(_ word: String) -> String {
            var w = word
            for suffix in ["ing", "ed", "es", "s"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
                w.removeLast(suffix.count)
                break
            }
            if w.count > 3, w.hasSuffix("e") { w.removeLast() }
            return w
        }
    }

    private static func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    // MARK: - Reopened sections

    /// Per section, the non-blank lines a round added and removed.
    private struct SectionEdits {
        var added: [String: Set<String>] = [:]
        var removed: [String: Set<String>] = [:]
    }

    private static func sectionEdits(from base: String, to plan: String) -> SectionEdits {
        var edits = SectionEdits()
        for hunk in PlanMetrics.hunks(from: base, to: plan) {
            let section = hunk.section ?? "(preamble)"
            func meaningful(_ lines: [String]) -> Set<String> {
                Set(lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
            }
            edits.added[section, default: []].formUnion(meaningful(hunk.newLines))
            edits.removed[section, default: []].formUnion(meaningful(hunk.oldLines))
        }
        return edits
    }

    /// A section is reopened by this round when it removed at least `reversalShare` of the
    /// lines an earlier round of the cycle added there: the earlier round's work, taken back.
    /// This is read off the stored plans, so it works on tapes from before proposals were kept.
    private static func reopenedSections(_ edits: [SectionEdits?], at i: Int, _ t: ConvergenceThresholds) -> [String] {
        guard let now = edits[i] else { return [] }
        let sections = now.removed.keys.filter { section in
            let removed = now.removed[section] ?? []
            return edits[..<i].contains { earlier in
                guard let added = earlier?.added[section], !added.isEmpty else { return false }
                return Double(added.intersection(removed).count) / Double(added.count) >= t.reversalShare
            }
        }
        return sections.sorted()
    }

    // MARK: - Trend and verdict

    /// The rounds the count and agreement trend is read from: from the last change of
    /// reviewer model on. A fallback model has its own issue budget, so comparing across the
    /// swap would read the swap as convergence or divergence.
    private static func compared(_ points: [ConvergencePoint]) -> ArraySlice<ConvergencePoint> {
        let restart = points.indices.dropFirst().last { i in
            guard let a = points[i - 1].reviewerModel, let b = points[i].reviewerModel else { return false }
            return a != b
        }
        return points[(restart ?? 0)...]
    }

    static func trend(_ points: [ConvergencePoint], _ t: ConvergenceThresholds) -> ConvergenceTrend {
        let window = compared(points)
        var trend = ConvergenceTrend()
        let models = points.compactMap(\.reviewerModel)
        trend.modelChanged = zip(models, models.dropFirst()).contains { $0 != $1 }
        if window.startIndex > 0 { trend.restartRound = window.first?.round }
        if window.count >= 2 {
            let last = window[window.endIndex - 1], prev = window[window.endIndex - 2]
            if prev.changeCount > 0 { trend.changeRatio = Double(last.changeCount) / Double(prev.changeCount) }
            if let a = last.agreeRatio, let b = prev.agreeRatio { trend.agreeDelta = a - b }
            trend.logSlope = slope(window.map { log(Double($0.changeCount) + 1) })
        }
        trend.hotSection = hotSection(points, t)
        trend.reopenedSection = reopenedSection(points, t)
        return trend
    }

    private static func slope(_ ys: [Double]) -> Double {
        let n = Double(ys.count)
        let meanX = (n - 1) / 2, meanY = ys.reduce(0, +) / n
        let num = ys.enumerated().reduce(0.0) { $0 + (Double($1.offset) - meanX) * ($1.element - meanY) }
        let den = ys.indices.reduce(0.0) { $0 + pow(Double($1) - meanX, 2) }
        return den == 0 ? 0 : num / den
    }

    private static func hotSection(_ points: [ConvergencePoint], _ t: ConvergenceThresholds) -> String? {
        guard points.count >= t.hotRuns, let last = points.last else { return nil }
        let recent = points.suffix(t.hotRuns)
        let total = last.sectionChurn.values.reduce(0, +)
        guard total > 0 else { return nil }
        let hot = last.sectionChurn.filter { section, lines in
            let prev = points[points.count - 2].sectionChurn[section] ?? 0
            return recent.allSatisfy { ($0.sectionChurn[section] ?? 0) > 0 }
                && lines >= prev
                && Double(lines) / Double(total) >= t.hotShare
        }
        return hot.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    private static func reopenedSection(_ points: [ConvergencePoint], _ t: ConvergenceThresholds) -> String? {
        guard let last = points.last else { return nil }
        return last.reopenedSections.first { section in
            points.filter { $0.reopenedSections.contains(section) }.count >= t.reopenRuns
        }
    }

    static func verdict(_ points: [ConvergencePoint], _ trend: ConvergenceTrend, _ t: ConvergenceThresholds) -> ConvergenceVerdict {
        guard points.count >= 2, let last = points.last else { return .tooEarly }
        // The executor already treats "the reviewer found nothing" as convergence.
        if last.changeCount == 0 { return .converging(settled: true) }
        let window = compared(points)
        guard window.count >= 2, let first = window.first else { return .tooEarly }
        let prev = window[window.endIndex - 2]

        // Most specific first: a named section is something the human can act on.
        if let section = trend.reopenedSection { return .diverging(reason: .reopened(section)) }
        if let section = trend.hotSection { return .diverging(reason: .hotSection(section)) }
        if Double(last.changeCount) >= t.growRatio * Double(prev.changeCount), last.changeCount - prev.changeCount >= t.growMin {
            return .diverging(reason: .growing)
        }
        if let delta = trend.agreeDelta, delta <= -t.agreeDrop { return .diverging(reason: .agreementFell) }

        if Double(last.changeCount) <= t.convergingRatio * Double(prev.changeCount),
           (trend.agreeDelta ?? 0) >= -t.agreeTolerance {
            let floor = max(Double(t.settledFloor), t.settledFraction * Double(first.changeCount))
            let settled = Double(last.changeCount) <= floor && (last.agreeRatio.map { $0 >= t.settledAgree } ?? true)
            return .converging(settled: settled)
        }
        return .plateau
    }

    // MARK: - Words

    /// "§4" for a numbered heading ("## 4. Rollout"), else the heading without its `#` marks.
    /// Public so the app's heatmap and churn lane name a section exactly as the verdict does.
    public static func label(_ heading: String) -> String {
        let text = heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        let number = text.prefix { $0.isNumber || $0 == "." }.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return number.isEmpty || number.first?.isNumber != true ? text : "§" + number
    }

    private static func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }
    private static func arrows<S: Sequence>(_ values: S) -> String where S.Element == Int {
        values.map(String.init).joined(separator: " → ")
    }
    private static func rounds(_ list: [Int]) -> String {
        let names = list.map { "R\($0)" }
        return names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    private static func explanation(_ stage: Stage, _ points: [ConvergencePoint], _ trend: ConvergenceTrend,
                                    _ verdict: ConvergenceVerdict) -> String {
        let window = compared(points)
        let seat = stage == .refine ? "reviewer" : "polisher"
        let restart = trend.restartRound.map { "\(seat) changed at R\($0); the trend restarts there" }
        let agrees = window.compactMap(\.agreeRatio)
        func history(_ section: String) -> String {
            arrows(points.compactMap { $0.sectionChurn[section] }) + " lines"
        }
        var parts: [String]
        switch verdict {
        case .tooEarly:
            return points.count < 2 ? "one round, nothing to compare yet" : restart ?? "one round, nothing to compare yet"
        case .converging(let settled):
            parts = [arrows(window.map(\.changeCount)) + " changes"]
            if agrees.count >= 2 { parts.append("agreement \(percent(agrees.first!)) → \(percent(agrees.last!))") }
            if settled { parts.append("settled") }
        case .plateau:
            parts = [arrows(window.map(\.changeCount)) + " changes"]
            if agrees.count >= 2 {
                let spread = agrees.last! - agrees.first!
                parts.append(abs(spread) <= 0.05
                    ? "agreement flat near \(percent(agrees.reduce(0, +) / Double(agrees.count)))"
                    : "agreement \(percent(agrees.first!)) → \(percent(agrees.last!))")
            }
            if let most = movedMost(window) { parts.append("\(label(most)) moved most") }
            if window.count == 2 { parts.append("only 2 rounds") }
        case .diverging(.growing):
            parts = ["changes rose " + arrows(window.map(\.changeCount))]
        case .diverging(.agreementFell):
            let prev = window[window.endIndex - 2].agreeRatio ?? 0, last = window.last?.agreeRatio ?? 0
            parts = ["agreement fell \(percent(prev)) → \(percent(last))"]
        case .diverging(.hotSection(let section)):
            let streak = points.reversed().prefix { ($0.sectionChurn[section] ?? 0) > 0 }.count
            let span = streak == points.count ? "all \(streak) rounds" : "the last \(streak) rounds"
            parts = ["\(label(section)) changed in \(span): \(history(section))"]
        case .diverging(.reopened(let section)):
            let reopened = points.filter { $0.reopenedSections.contains(section) }.map(\.round)
            parts = ["\(label(section)) reopened in \(rounds(reopened)): \(history(section))"]
            if let n = points.last?.reopenCount, n > 0 {
                parts.append("\(n) rejected change\(n == 1 ? "" : "s") re-proposed")
            }
        }
        if let restart { parts.append(restart) }
        return parts.joined(separator: " · ")
    }

    /// The section with the most churn across the compared rounds.
    private static func movedMost(_ window: ArraySlice<ConvergencePoint>) -> String? {
        var totals: [String: Int] = [:]
        for p in window { totals.merge(p.sectionChurn, uniquingKeysWith: +) }
        return totals.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    private static func suggestedAction(_ stage: Stage, _ points: [ConvergencePoint], _ verdict: ConvergenceVerdict) -> String {
        switch verdict {
        case .tooEarly:
            return ""
        case .converging(settled: true):
            return stage == .refine ? "Converged: ⏭ to encode" : "Converged: ⏭ to the next stage"
        case .converging(settled: false):
            return "Converging: one more round should help"
        case .plateau:
            // The methodology's "plateau at low quality" advice is to reframe, not to repeat.
            let section = movedMost(compared(points)).map(label) ?? "a section"
            return "Plateau: consider annotating \(section) or stopping. Another round is unlikely to change much."
        case .diverging(.hotSection(let section)), .diverging(.reopened(let section)):
            let s = label(section)
            return "Diverging: \(s) keeps changing. Refining more will not settle it; decide \(s) yourself."
        case .diverging(.growing):
            return "Diverging: each round finds more. Step back and reframe the plan rather than refining it."
        case .diverging(.agreementFell):
            return "Diverging: the integrator is rejecting more. Review the last round's diffs before running another."
        }
    }
}
