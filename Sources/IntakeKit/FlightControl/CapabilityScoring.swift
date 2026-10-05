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
