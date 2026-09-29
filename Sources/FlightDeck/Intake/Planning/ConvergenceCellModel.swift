import Foundation
import IntakeKit

/// The LCD's CONVERGENCE cell (spec §8.1): the state word, the latest round's change count, the
/// sparkline of changes per round in the current cycle, and what its hover card says.
///
/// Everything here is read off the engine's `ConvergenceCycle` — the verdict, its explanation and
/// its suggested action are the engine's, never re-derived — so the cell, the card and the
/// heatmap can't disagree with each other or with the fold. The first four fields are the ones
/// `LCDModel` and `ControlBar` were built against before this derivation existed; the rest have
/// defaults so a hand-made cell (a render fixture) still needs only those four.
struct ConvergenceCellModel: Equatable {
    /// "CONVERGING ↘", "PLATEAU →", "DIVERGING ↗" or "TOO EARLY". Never cut short: a squeezed
    /// cell falls back to the arrow and the count (`LCDModel.arrowAndCount`).
    var word: String
    var latest: Int
    /// changeCount per round of the current cycle, oldest first, ending at `latest`.
    var spark: [Double]
    /// Amber only for diverging (spec §8.1) — colour for exceptions only.
    var tone: LCDCell.Tone
    var stage: Stage = .refine
    /// The card's second line: the count and the verdict's reason, "5 changes · settled".
    var detail: String = ""
    /// Indices into `spark` where the numbers stop being comparable with the point before: the
    /// reviewer's (or polisher's) model changed, or the round is the first one an Extend added.
    /// The sparkline marks them and `cardLines` says what happened.
    var discontinuities: [Int] = []
    /// The series line, the sections line, then one line per discontinuity.
    var cardLines: [String] = []
    /// The engine's `suggestedAction`; empty while it is too early to say.
    var action: String = ""
    /// The section the verdict names (a hot or reopened one), which the heatmap outlines.
    var hotSection: String?
    /// The count at or under which the cycle would read as settled — the dashed floor the
    /// sparkline draws. Nil with fewer than two rounds to compare.
    var settledFloor: Double?

    /// The action's first sentence, the part the card sets in bold: "Diverging: §4 keeps changing".
    var actionHeadline: String? { Self.splitAction(action)?.headline }
    /// The rest of the action, if any: "Refining more will not settle it; decide §4 yourself."
    var actionDetail: String? { Self.splitAction(action)?.detail }

    /// An engine action split at its first ". " into the bold headline and the rest — shared with
    /// the COVERAGE card (`CoverageCellModel`), so the two cards can never set the same kind of
    /// sentence differently. Nil for an empty action (too early to say).
    static func splitAction(_ action: String) -> (headline: String, detail: String?)? {
        guard !action.isEmpty else { return nil }
        guard let stop = action.range(of: ". ") else {
            return (action.hasSuffix(".") ? String(action.dropLast()) : action, nil)
        }
        return (String(action[..<stop.lowerBound]), String(action[stop.upperBound...]))
    }
}

extension ConvergenceCellModel {
    /// The current cycle's cell — the LAST refine or polish cycle on the tape; nil before there
    /// is one. `plannedRounds` is the cycle's length before any Extend (the config's
    /// `refinementCap` or `polishCap`); a round past it is marked as a discontinuity.
    init?(cycles: [ConvergenceCycle], plannedRounds: Int? = nil) {
        guard let cycle = cycles.last, let last = cycle.points.last else { return nil }
        let points = cycle.points
        let count = "\(last.changeCount) change\(last.changeCount == 1 ? "" : "s")"
        let reason: String
        switch cycle.verdict {
        case .tooEarly:
            word = "TOO EARLY"; reason = "one round"
        case .converging(let settled):
            word = "CONVERGING ↘"; reason = settled ? "settled" : "narrowing"
        case .plateau:
            word = "PLATEAU →"; reason = "flat"
        case .diverging(let why):
            word = "DIVERGING ↗"
            switch why {
            case .hotSection(let s): reason = "\(ConvergenceSeries.label(s)) keeps changing"
            case .reopened(let s): reason = "\(ConvergenceSeries.label(s)) reopened"
            case .growing: reason = "growing"
            case .agreementFell: reason = "agreement fell"
            }
        }
        latest = last.changeCount
        spark = points.map { Double($0.changeCount) }
        tone = if case .diverging = cycle.verdict { .amber } else { .normal }
        stage = cycle.stage
        detail = "\(count) · \(reason)"
        action = cycle.suggestedAction
        hotSection = Self.namedSection(cycle)

        let seat = cycle.stage == .refine ? "Reviewer" : "Polisher"
        var breaks: [(index: Int, line: String)] = []
        for i in points.indices.dropFirst() {
            guard let a = points[i - 1].reviewerModel, let b = points[i].reviewerModel, a != b else { continue }
            let restarts = cycle.trend.restartRound == points[i].round ? "; the trend restarts there" : ""
            breaks.append((i, "\(seat) changed at R\(points[i].round) (\(Self.name(a)) → \(Self.name(b)))\(restarts)"))
        }
        if let planned = plannedRounds, let i = points.firstIndex(where: { $0.round > planned }) {
            breaks.append((i, "R\(points[i].round) is an extra round, past the \(planned) planned"))
        }
        discontinuities = Array(Set(breaks.map(\.index))).sorted()
        cardLines = [Self.seriesLine(cycle)] + [Self.sectionsLine(points)].compactMap { $0 } + breaks.map(\.line)

        // The engine's own settled test, drawn: at or under max(floor, fraction × the first
        // compared round). Compared rounds start at the last model change.
        if points.count >= 2 {
            let t = ConvergenceThresholds.default
            let first = points.first { $0.round == (cycle.trend.restartRound ?? points[0].round) } ?? points[0]
            settledFloor = max(Double(t.settledFloor), t.settledFraction * Double(first.changeCount))
        }
    }

    /// The engine's explanation without its "reviewer changed at R3" clause — the card gives
    /// that its own line, with the models, and saying it twice reads as two events.
    private static func seriesLine(_ cycle: ConvergenceCycle) -> String {
        let parts = cycle.explanation.components(separatedBy: " · ")
            .filter { !$0.hasPrefix("reviewer changed at") && !$0.hasPrefix("polisher changed at") }
        return parts.isEmpty ? "nothing to compare since the change yet" : parts.joined(separator: " · ")
    }

    /// "4 of 7 sections still since R2": of the sections the cycle changed, those the last round
    /// left alone, and the latest round any of them last moved in. Nil when the cycle has no
    /// per-section numbers (polish, or plans that weren't on disk).
    private static func sectionsLine(_ points: [ConvergencePoint]) -> String? {
        let all = Set(points.flatMap { $0.sectionChurn.filter { $0.value > 0 }.keys })
        guard let last = points.last, !all.isEmpty else { return nil }
        let still = all.filter { (last.sectionChurn[$0] ?? 0) == 0 }
        let noun = all.count == 1 ? "section" : "sections"
        guard !still.isEmpty else {
            return all.count == 1 ? "\(ConvergenceSeries.label(all.first!)) changed in R\(last.round)"
                : "all \(all.count) \(noun) changed in R\(last.round)"
        }
        let since = still.compactMap { section in points.last { ($0.sectionChurn[section] ?? 0) > 0 }?.round }.max() ?? last.round
        return "\(still.count) of \(all.count) \(noun) still since R\(since)"
    }

    /// The section the verdict names, else the trend's hot or reopened one.
    static func namedSection(_ cycle: ConvergenceCycle) -> String? {
        switch cycle.verdict {
        case .diverging(.hotSection(let s)), .diverging(.reopened(let s)): s
        default: cycle.trend.reopenedSection ?? cycle.trend.hotSection
        }
    }

    /// "codex gpt-6-sol" — the harness and the model, the two things a swap changes.
    private static func name(_ m: ModelChoice) -> String { "\(m.harness.rawValue) \(m.model)" }
}

// MARK: - Heatmap

/// The section heatmap (spec §8.3): rows are the plan sections the cycle changed, columns its
/// rounds, and each cell's luminance the lines that round changed in that section over the
/// cycle's largest cell — so the brightest cell is 1 and a quiet section reads dark. It answers
/// the one question the sparkline can't: which part is still moving.
struct HeatmapModel: Equatable {
    /// Section headings as `PlanMetrics` keys them ("## 4. Dispatch rules"), in plan order.
    var sections: [String]
    /// "R1", "R2", … — the cycle's rounds.
    var rounds: [String]
    /// [section][round], 0…1.
    var cells: [[Double]]
    /// Each round's agreement ((agree + ½·somewhat) / verdicts), nil where there was no tally.
    var agree: [Double?]
    /// The sections the verdict names — outlined in amber.
    var hot: Set<String>

    var stage: Stage
    /// "§4" per section (the verdict's own naming), and the heading's words after the number.
    var labels: [String]
    var names: [String]
    /// [section][round] lines changed, for the cell's figure.
    var lines: [[Int]]
    /// Changes proposed (or ops changed) per round.
    var counts: [Int]
    /// The checkpoint each round landed as — what a click selects.
    var checkpoints: [Int]
    /// The tape slot each round sits in (`TapeSlot.id`), so columns align under the tape.
    var slotIDs: [String]
    /// Per section, the churn lane's caption ("still since R2", "settling", …).
    var captions: [String?]

    init(cycle: ConvergenceCycle) {
        let points = cycle.points
        let changed = points.flatMap { p in p.sectionChurn.filter { $0.value > 0 }.map(\.key) }
        var firstSeen: [String: Int] = [:]
        for (i, s) in changed.enumerated() where firstSeen[s] == nil { firstSeen[s] = i }
        sections = firstSeen.keys.sorted { a, b in
            let (na, nb) = (Self.number(a), Self.number(b))
            return na != nb ? na < nb : firstSeen[a]! < firstSeen[b]!
        }
        rounds = points.map { "R\($0.round)" }
        lines = sections.map { s in points.map { $0.sectionChurn[s] ?? 0 } }
        let top = Double(lines.flatMap { $0 }.max() ?? 0)
        cells = lines.map { row in row.map { top > 0 ? Double($0) / top : 0 } }
        agree = points.map(\.agreeRatio)
        hot = Self.hotSections(cycle)
        stage = cycle.stage
        labels = sections.map(Self.label)
        names = sections.map(Self.name)
        counts = points.map(\.changeCount)
        checkpoints = points.map(\.checkpoint)
        slotIDs = points.map { "\($0.stage.rawValue)-\($0.round)" }
        captions = sections.map { ChurnLaneModel(cycle: cycle, section: $0).caption }
    }

    /// "SECTION CHURN · REFINE ×4".
    var title: String { "SECTION CHURN · \(stage.rawValue.uppercased()) ×\(rounds.count)" }

    func row(of section: String) -> Int? { sections.firstIndex(of: section) }

    /// Plan order without the plan: numbered headings by number (so §10 follows §4, which a
    /// string sort gets wrong), the preamble first, unnumbered headings after, by first change.
    private static func number(_ heading: String) -> Int {
        if heading == "(preamble)" { return -1 }
        let label = ConvergenceSeries.label(heading)
        guard label.hasPrefix("§") else { return .max }
        return Int(label.dropFirst().prefix { $0.isNumber }) ?? .max
    }

    static func label(_ heading: String) -> String {
        heading == "(preamble)" ? "—" : ConvergenceSeries.label(heading)
    }

    /// The heading's words after its number: "Dispatch rules" for "## 4. Dispatch rules"; empty
    /// for an unnumbered heading, whose label already is its words.
    static func name(_ heading: String) -> String {
        if heading == "(preamble)" { return "Preamble" }
        guard ConvergenceSeries.label(heading).hasPrefix("§") else { return "" }
        let text = heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return text.drop { $0.isNumber || $0 == "." }.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Churn lane

/// One heading's marker in the plan's churn lane (spec §8.2): a bar per round of the current
/// cycle, scaled like the heatmap (over the cycle's largest cell, so lanes compare with each
/// other), a quiet caption once the section has stopped moving, and amber while it is the
/// section the verdict names.
struct ChurnLaneModel: Equatable {
    /// 0…1 per round.
    var bars: [Double]
    /// "still since R2" — the section last changed in R2 and not since. Nil while it is still
    /// changing, and for a section the cycle never touched: it has nothing to be still since.
    var stillSince: String?
    var hot: Bool
    var lines: [Int]
    var rounds: [String]
    /// What the lane writes beside the bars: "reopened ×2" or "changed in 4 of 4" when hot,
    /// `stillSince` once still, "settling" while no bigger than its last change, "moving" while
    /// growing, "new in R4" for a first change.
    var caption: String?

    init(cycle: ConvergenceCycle, section: String) {
        let points = cycle.points
        lines = points.map { $0.sectionChurn[section] ?? 0 }
        rounds = points.map { "R\($0.round)" }
        let top = Double(points.flatMap { $0.sectionChurn.values }.max() ?? 0)
        bars = lines.map { top > 0 ? Double($0) / top : 0 }
        hot = HeatmapModel.hotSections(cycle).contains(section)
        let lastChanged = lines.lastIndex { $0 > 0 }
        stillSince = lastChanged.flatMap { $0 < lines.count - 1 ? "still since \(rounds[$0])" : nil }

        let reopened = points.filter { $0.reopenedSections.contains(section) }.count
        if hot {
            caption = reopened > 0 ? "reopened ×\(reopened)" : "changed in \(lines.filter { $0 > 0 }.count) of \(lines.count)"
        } else if let stillSince {
            caption = stillSince
        } else if let i = lastChanged {
            let earlier = lines[..<i].filter { $0 > 0 }
            caption = earlier.isEmpty ? "new in \(rounds[i])" : lines[i] <= earlier.last! ? "settling" : "moving"
        } else {
            caption = nil
        }
    }

    /// A section the cycle never changed draws no marker at all.
    var isEmpty: Bool { lines.allSatisfy { $0 == 0 } }

    /// What the reviewer proposed for `section`, round by round, from each checkpoint's kept
    /// `changes.json`, with the integrator's verdict from `verdicts.json` where it was kept —
    /// the hover on an amber marker. A reviewer names sections loosely ("4. Dispatch rules",
    /// "§4 Dispatch rules"), so they are matched by section number, else by their words.
    static func versions(cycle: ConvergenceCycle, section: String, loadFile: (Int, String) -> Data?) -> [SectionVersion] {
        let key = sectionKey(section)
        return cycle.points.flatMap { point -> [SectionVersion] in
            guard let data = loadFile(point.checkpoint, "changes.json"),
                  let changes = try? IntakeJSON.decoder.decode([ProposedChange].self, from: data) else { return [] }
            let verdicts = loadFile(point.checkpoint, "verdicts.json")
                .flatMap { try? IntakeJSON.decoder.decode([ChangeVerdict].self, from: $0) }
                .map { Dictionary($0.map { ($0.index, $0.verdict) }, uniquingKeysWith: { a, _ in a }) } ?? [:]
            return changes.enumerated().compactMap { i, change in
                sectionKey(change.section) == key
                    ? SectionVersion(round: "R\(point.round)", text: change.edit, verdict: verdicts[i]) : nil
            }
        }
    }

    /// The sentences of `section` in `plan` that the cycle's proposals kept rewriting — the
    /// spec §8.2 amber highlight. A sentence counts when its words match a proposal's (Jaccard
    /// ≥ 0.5) in at least two rounds: one round proposing it is a change, two is the section
    /// going back and forth over it. UTF-16 ranges of `plan`, the sentence's own text only.
    static func flippingSentences(in plan: String, section: String, versions: [SectionVersion]) -> [NSRange] {
        let ns = plan as NSString
        var inSection = false
        var out: [NSRange] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            let text = ns.substring(with: line)
            if text.hasPrefix("#") {
                inSection = text.trimmingCharacters(in: .whitespacesAndNewlines) == section
                continue
            }
            guard inSection else { continue }
            for sentence in sentences(in: line, of: ns) {
                let words = wordSet(ns.substring(with: sentence))
                let rounds = Set(versions.filter { jaccard(words, wordSet($0.text)) >= 0.5 }.map(\.round))
                if rounds.count >= 2 { out.append(sentence) }
            }
        }
        return out
    }

    /// `ranges` with every part that lies inside `holes` cut out.
    static func subtracting(_ ranges: [NSRange], _ holes: [NSRange]) -> [NSRange] {
        ranges.flatMap { range -> [NSRange] in
            var pieces = [range]
            for hole in holes {
                pieces = pieces.flatMap { piece -> [NSRange] in
                    let overlap = NSIntersectionRange(piece, hole)
                    guard overlap.length > 0 else { return [piece] }
                    return [NSRange(location: piece.location, length: overlap.location - piece.location),
                            NSRange(location: NSMaxRange(overlap), length: NSMaxRange(piece) - NSMaxRange(overlap))]
                        .filter { $0.length > 0 }
                }
            }
            return pieces
        }
    }

    /// A line's sentences after its list marker, each ending at its own ". ", "? " or "! ".
    private static func sentences(in line: NSRange, of ns: NSString) -> [NSRange] {
        let text = ns.substring(with: line)
        let marker = listMarker.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count))
        var start = marker.map { NSMaxRange($0.range) } ?? 0
        let chars = Array(text.utf16)
        var end = chars.count
        while end > start, [10, 13, 32].contains(chars[end - 1]) { end -= 1 }
        var out: [NSRange] = []
        var i = start
        while i < end {
            if [46, 63, 33].contains(chars[i]), i + 1 == end || chars[i + 1] == 32 {
                out.append(NSRange(location: line.location + start, length: i + 1 - start))
                start = i + 1
                while start < end, chars[start] == 32 { start += 1 }
                i = start
                continue
            }
            i += 1
        }
        if start < end { out.append(NSRange(location: line.location + start, length: end - start)) }
        return out
    }

    /// "- ", "* ", "12. " and "> " at a line's start — so a sentence starting "6 jobs" keeps its 6.
    private static let listMarker = try! NSRegularExpression(pattern: #"^\s*(?:[-*+>]|\d+[.)])\s+"#)

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// "4" for any spelling of a numbered heading; otherwise its lowercased words.
    static func sectionKey(_ heading: String) -> String {
        let text = heading.drop { $0 == "#" || $0 == "§" || $0 == " " }
        let number = text.prefix { $0.isNumber }
        if !number.isEmpty { return String(number) }
        return text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}

/// One round's proposal for a section, as the amber marker's hover lists it.
struct SectionVersion: Equatable {
    let round: String
    let text: String
    let verdict: Verdict?
}

extension HeatmapModel {
    /// The sections the verdict names — `hot` without building the whole map.
    static func hotSections(_ cycle: ConvergenceCycle) -> Set<String> {
        Set([ConvergenceCellModel.namedSection(cycle), cycle.trend.hotSection, cycle.trend.reopenedSection].compactMap { $0 })
    }
}
