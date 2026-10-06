import Foundation

/// Turns benchmark rows into per-dimension scores (spec §6). Pure: every rule is a table test.
public enum CapabilityScoring {
    /// Each value's percentile among `values`: worst 0, best 1, ties sharing the middle of the
    /// places they span. Nil below two values — one row ranks against nothing, and calling it
    /// 1.0 (or 0.5) would invent a signal the benchmark never gave.
    public static func percentiles(_ values: [Double], higherIsBetter: Bool) -> [Double]? {
        guard values.count >= 2 else { return nil }
        let span = Double(values.count - 1)
        return values.map { v in
            var worse = 0
            var equal = 0
            for w in values {
                if w == v { equal += 1 } else if (higherIsBetter ? (w < v) : (w > v)) { worse += 1 }
            }
            return (Double(worse) + Double(equal - 1) / 2) / span
        }
    }

    private struct Sum {
        var num = 0.0
        var den = 0.0
        var sources: [String] = []
    }

    /// Known dimensions with a weight in (0, 1], sorted. A bad weight in a hand-edited config
    /// contributes nothing rather than skewing a mean (`IndexSourceRegistry.problems` reports it).
    static func usableWeights(_ s: IndexSource) -> [(String, Double)] {
        s.dimensions.filter { Dimensions.isKnown($0.key) && $0.value > 0 && $0.value <= 1 }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Per benchmark: percentile among ALL that source's accepted rows — unmapped names included,
    /// since they are real competitors on that benchmark. Per dimension: the weighted mean over
    /// the sources present for the model; confidence = present weight / the dimension's total
    /// weight across enabled sources. Two names mapped to one model in one source keep the better
    /// row. Disabled sources and sources with a unit nobody knows are left out entirely.
    public static func computeScores(results: [SourceResult], sources: [IndexSource], aliases: AliasTable)
        -> (scores: [ModelScores], unmapped: [UnmappedName]) {
        let enabled = sources.filter(\.enabled)
        var total: [String: Double] = [:]
        for s in enabled where s.indexUnit != nil {
            for (d, w) in usableWeights(s) { total[d, default: 0] += w }
        }

        var sums: [ModelRef: [String: Sum]] = [:]
        var unmapped: Set<UnmappedName> = []
        for result in results {
            guard let source = enabled.first(where: { $0.id == result.sourceID }), let unit = source.indexUnit else { continue }
            let ranks = percentiles(result.rows.map(\.score), higherIsBetter: unit.higherIsBetter)
            var best: [ModelRef: Double] = [:]
            for (i, row) in result.rows.enumerated() {
                guard let ref = aliases.model(source: source.id, benchmarkModel: row.benchmarkModel) else {
                    unmapped.insert(UnmappedName(source: source.id, benchmarkModel: row.benchmarkModel))
                    continue
                }
                guard let ranks else { continue }
                best[ref] = max(best[ref] ?? -1, ranks[i])
            }
            for (ref, p) in best {
                for (d, w) in usableWeights(source) {
                    var cell = sums[ref, default: [:]][d] ?? Sum()
                    cell.num += w * p
                    cell.den += w
                    cell.sources.append(source.id)
                    sums[ref, default: [:]][d] = cell
                }
            }
        }

        let scores = sums.map { ref, dims in
            ModelScores(model: ref, dimensions: Dictionary(uniqueKeysWithValues: dims.map { d, s in
                (d, DimensionScore(score: s.num / s.den, confidence: min(1, s.den / (total[d] ?? s.den)),
                                   origin: .computed, sources: s.sources.sorted()))
            }))
        }
        return (scores.sorted { IndexKeys.key($0.model) < IndexKeys.key($1.model) }, unmapped.sorted())
    }

    /// Computed scores with the config's hand-entered and inherited scores laid over them.
    /// Per dimension: manual > computed > inherited. A hand score has confidence 1. Inheritance
    /// copies the base's computed-plus-manual scores (not the base's own inheritance, so a chain
    /// or a cycle cannot form) at `discount`, keeping the base's confidence.
    public static func overlay(_ computed: [ModelScores], manual: [ManualModelScores]) -> [ModelScores] {
        var byKey: [String: ModelScores] = [:]
        for m in computed { byKey[IndexKeys.key(m.model)] = m }
        let computedByKey = byKey
        var manualByKey: [String: ManualModelScores] = [:]
        for m in manual { manualByKey[IndexKeys.key(m.model)] = m }

        for m in manual {
            let key = IndexKeys.key(m.model)
            var dims = computedByKey[key]?.dimensions ?? [:]
            if let base = m.inheritFrom {
                let baseKey = IndexKeys.key(base)
                var baseDims = computedByKey[baseKey]?.dimensions ?? [:]
                if let baseManual = manualByKey[baseKey] { baseDims.merge(handEntered(baseManual)) { _, hand in hand } }
                for (d, s) in baseDims where dims[d] == nil {
                    dims[d] = DimensionScore(score: s.score * m.discount, confidence: s.confidence,
                                             origin: .inherited, inheritedFrom: base, sources: s.sources)
                }
            }
            dims.merge(handEntered(m)) { _, hand in hand }
            byKey[key] = ModelScores(model: m.model, dimensions: dims)
        }
        return byKey.values.sorted { IndexKeys.key($0.model) < IndexKeys.key($1.model) }
    }

    static func handEntered(_ m: ManualModelScores) -> [String: DimensionScore] {
        var out: [String: DimensionScore] = [:]
        for (d, v) in m.dimensions where Dimensions.isKnown(d) {
            out[d] = DimensionScore(score: min(1, max(0, v)), confidence: 1, origin: .manual)
        }
        return out
    }
}

extension CapabilityScoring {
    /// A kind's score from one model's dimensions: Σ weight × score over the dimensions that have
    /// data, divided by the weight that had data; confidence is that weight's share of the kind's
    /// total. Nil when no weighted dimension has data. Summed in sorted dimension order:
    /// dictionary order changes run to run, and a float sum taken in another order can differ in
    /// its last bit — enough to flip a tie between two models.
    public static func kindScore(_ kind: TaskKind, _ dimensions: [String: DimensionScore]) -> (score: Double, confidence: Double)? {
        let weights = kind.dimensions.filter { Dimensions.isKnown($0.key) && $0.value > 0 }
        let order = weights.keys.sorted()
        let total = order.reduce(0.0) { $0 + (weights[$1] ?? 0) }
        guard total > 0 else { return nil }
        var num = 0.0
        var present = 0.0
        for d in order {
            guard let s = dimensions[d], let w = weights[d] else { continue }
            num += w * s.score
            present += w
        }
        guard present > 0 else { return nil }
        return (num / present, present / total)
    }

    /// A catalog candidate has no knobs and stands for every scored knob variant of its model; a
    /// candidate that names knobs (a rule's assignment) matches only that exact variant.
    public static func matches(candidate: ModelRef, scored: ModelRef) -> Bool {
        candidate.harness == scored.harness && candidate.model == scored.model
            && (candidate.knobs.isEmpty || candidate.knobs == scored.knobs)
    }

    /// Best first; models with no data for the kind are omitted, never scored zero; equal scores
    /// keep the candidates' (catalog) order. A bare candidate returns its best variant's
    /// `ModelRef`, knobs included, so the router can write those knobs into the block.
    public static func rank(kind: TaskKind, candidates: [ModelRef], scores: [ModelScores]) -> [ScoredModel] {
        var ranked: [(order: Int, model: ScoredModel)] = []
        for (i, candidate) in candidates.enumerated() {
            var best: ScoredModel?
            for variant in scores where matches(candidate: candidate, scored: variant.model) {
                guard let r = kindScore(kind, variant.dimensions) else { continue }
                let s = ScoredModel(model: variant.model, score: r.score, confidence: r.confidence)
                if let b = best, b.score > s.score || (b.score == s.score && b.confidence >= s.confidence) { continue }
                best = s
            }
            if let best { ranked.append((i, best)) }
        }
        return ranked.sorted {
            $0.model.score != $1.model.score ? $0.model.score > $1.model.score : $0.order < $1.order
        }.map(\.model)
    }

    /// One model's score on one dimension, resolving a bare ref to its best variant there.
    public static func dimensionScore(_ ref: ModelRef, _ dimension: String, in scores: [ModelScores])
        -> (model: ModelRef, score: DimensionScore)? {
        var best: (model: ModelRef, score: DimensionScore)?
        for variant in scores where matches(candidate: ref, scored: variant.model) {
            guard let s = variant.dimensions[dimension] else { continue }
            if let b = best, b.score.score >= s.score { continue }
            best = (variant.model, s)
        }
        return best
    }

    /// The rows behind one heatmap cell: every row, in sources feeding `dimension`, that the
    /// snapshot's own aliases map to exactly `model`. Uses the snapshot's aliases, not today's
    /// config, so a cell cites what its score was computed from.
    public static func citations(for model: ModelRef, dimension: String, snapshot: IndexSnapshot,
                                 sources: [IndexSource]) -> [Citation] {
        let aliases = AliasTable(entries: snapshot.aliases)
        var out: [Citation] = []
        for result in snapshot.sources {
            guard let source = sources.first(where: { $0.id == result.sourceID }),
                  (source.dimensions[dimension] ?? 0) > 0 else { continue }
            for row in result.rows where aliases.model(source: source.id, benchmarkModel: row.benchmarkModel) == model {
                out.append(Citation(sourceID: source.id, sourceName: source.name, benchmarkModel: row.benchmarkModel,
                                    score: row.score, unit: row.unit, url: row.url, quotedFigure: row.quotedFigure,
                                    retrievedAt: row.retrievedAt, stale: result.stale))
            }
        }
        return out
    }
}

/// One cited row, as the Settings click-through shows it.
public struct Citation: Equatable, Sendable, Identifiable {
    public var sourceID: String
    public var sourceName: String
    public var benchmarkModel: String
    public var score: Double
    public var unit: IndexUnit
    public var url: String
    public var quotedFigure: String
    public var retrievedAt: String?
    public var stale: Bool
    public var id: String { "\(sourceID)|\(benchmarkModel)|\(url)" }
    public init(sourceID: String, sourceName: String, benchmarkModel: String, score: Double, unit: IndexUnit,
                url: String, quotedFigure: String, retrievedAt: String?, stale: Bool) {
        self.sourceID = sourceID; self.sourceName = sourceName; self.benchmarkModel = benchmarkModel
        self.score = score; self.unit = unit; self.url = url; self.quotedFigure = quotedFigure
        self.retrievedAt = retrievedAt; self.stale = stale
    }
}

/// The `CapabilityIndex` conformer: one snapshot's scores (with hand scores overlaid), frozen.
/// A value, so a router holding one never sees it change under a ranking; the app swaps in a
/// new one through `LiveCapabilityIndex` when a snapshot applies.
public struct SnapshotCapabilityIndex: CapabilityIndex {
    public let scores: [ModelScores]
    public let snapshotDate: Date?
    public init(scores: [ModelScores], snapshotDate: Date?) { self.scores = scores; self.snapshotDate = snapshotDate }
    public static let empty = SnapshotCapabilityIndex(scores: [], snapshotDate: nil)

    public func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel] {
        CapabilityScoring.rank(kind: kind, candidates: candidates, scores: scores)
    }
}

extension IndexSnapshot {
    /// The one place a snapshot is built from source results — for a refresh and for an alias
    /// rescore alike — so the two can never score the same rows differently.
    public static func assemble(results: [SourceResult], sources: [IndexSource], aliases: AliasTable,
                                createdAt: Date) -> IndexSnapshot {
        let (scores, unmapped) = CapabilityScoring.computeScores(results: results, sources: sources, aliases: aliases)
        return IndexSnapshot(createdAt: createdAt, sources: results, aliases: aliases.confirmed,
                             scores: scores, unmapped: unmapped)
    }
}
