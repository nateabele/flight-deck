import FleetKit
import Foundation
import IntakeKit

/// A checkpoint's plan as the phone reads it (spec §6.3). Block indices are
/// `PlanBlocks.split(markdown)` — the same function the phone runs, so an index names the same
/// block on both ends.
enum IntakePlanProjection {
    /// `##` and `###` headings, each with the block it opens. `churn` is one map per round of the
    /// current cycle, keyed as the engine keys it: `PlanMetrics.sectionChurn` names a section by
    /// its whole heading LINE ("## 7. Credential paths"), and so does a diverging verdict. A key
    /// that is not that exact line still counts when its `ConvergenceSeries.label` matches
    /// ("§7") — a reviewer names sections loosely, and a missed key would read as a quiet
    /// section on the phone while the Mac's lane shows it moving.
    static func outline(markdown: String, blocks: PlanBlocks, churn: [[String: Int]],
                        divergingSection: String?) -> [WireSection] {
        blocks.blocks.compactMap { block -> WireSection? in
            let line = block.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let hashes = line.prefix { $0 == "#" }.count
            guard (2...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
            let heading = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
            let exact = line.trimmingCharacters(in: .whitespaces)
            let key = ConvergenceSeries.label(heading)
            let perRound = churn.map { round in
                round[exact] ?? round.filter { ConvergenceSeries.label($0.key) == key }.values.reduce(0, +)
            }
            // "Round N": the last round that changed it, when a later round left it alone.
            let settled = perRound.lastIndex { $0 > 0 }.flatMap { $0 + 1 < perRound.count ? "Round \($0 + 1)" : nil }
            let diverging = divergingSection.map { ConvergenceSeries.label($0) == key } ?? false
            return WireSection(heading: heading, level: hashes, blockIndex: block.index,
                               churn: perRound, diverging: diverging, settledSince: settled)
        }
    }

    /// Whitespace runs to one space and inline markers (`**`, `*`, `_`, `` ` ``, `[text](url)` →
    /// text) removed — how rendered text a person selected compares to the source it came from.
    static func normalized(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "`", "*", "_"] { t = t.replacingOccurrences(of: marker, with: "") }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `note` with the block its quote now sits in. A quote no block contains any more is left
    /// detached (`blockIndex` nil) rather than pinned to a near miss — a note on the wrong
    /// paragraph is worse than one listed apart.
    static func locate(_ note: PlanNote, consumed: Bool, in blocks: PlanBlocks) -> WireNote {
        let quote = note.anchor?.quote
        let index = quote.flatMap { q -> Int? in
            let needle = normalized(q)
            guard !needle.isEmpty else { return nil }
            return blocks.blocks.first { normalized($0.text).contains(needle) }?.index
        }
        return WireNote(id: note.id, kind: note.kind.rawValue, text: note.note, quote: quote,
                        section: note.anchor?.section, consumed: consumed, blockIndex: index)
    }

    /// Blocks by verbatim text: a block of `current` the parent lacks is added; a block of the
    /// parent `current` lacks is removed, placed after the surviving block it followed.
    static func blockDiff(current: PlanBlocks, parent: PlanBlocks) -> (added: [Int], removed: [WireRemovedBlock]) {
        let before = Set(parent.blocks.map(\.text)), after = Set(current.blocks.map(\.text))
        let added = current.blocks.filter { !before.contains($0.text) }.map(\.index)
        var removed: [WireRemovedBlock] = []
        var lastSurvivor: Int?
        for block in parent.blocks {
            if after.contains(block.text) {
                lastSurvivor = current.blocks.first { $0.text == block.text }?.index
            } else {
                removed.append(WireRemovedBlock(after: lastSurvivor, text: block.text))
            }
        }
        return (added, removed)
    }

    /// `requested`'s plan (the plan head when nil), or nil for an unknown intake or a checkpoint
    /// with no plan. The diff is against the previous checkpoint that HAS a plan
    /// (`ShapingModel.previousPlanCheckpoint`, as the Mac's own diff does) — an encode or polish
    /// checkpoint's parent carries a change set, and diffing against nothing marks every block new.
    @MainActor
    static func plan(_ id: UUID, checkpoint requested: Int?, changes: Bool, service: IntakeService) -> WireIntakePlan? {
        guard service.intakes.contains(where: { $0.id == id }) else { return nil }
        let tape = service.storedTape(id)
        let load: (Int, String) -> Data? = { service.checkpointFile(id, checkpoint: $0, $1) }
        guard let checkpointID = requested ?? PlanSection.planHead(tape: tape, loadFile: load),
              let checkpoint = tape.checkpoints.first(where: { $0.id == checkpointID }),
              let markdown = PlanSection.effectivePlan(checkpoint: checkpointID, tape: tape, loadFile: load)
        else { return nil }
        let blocks = PlanBlocks.split(markdown)
        let cycle = service.convergence[id]?.last
        let churn = cycle?.points.filter { $0.checkpoint <= checkpointID }.map(\.sectionChurn) ?? []
        let diverging: String? = switch cycle?.verdict {
        case .diverging(.hotSection(let s))?, .diverging(.reopened(let s))?: s
        default: nil
        }
        let notes = tape.checkpoints.flatMap(\.record.annotations).map { locate($0, consumed: true, in: blocks) }
            + tape.pendingNotes.map { locate($0, consumed: false, in: blocks) }
        var added: [Int]?, removed: [WireRemovedBlock]?
        if changes,
           let parentID = ShapingModel.previousPlanCheckpoint(before: checkpointID, in: tape, loadFile: load),
           let parentText = PlanSection.effectivePlan(checkpoint: parentID, tape: tape, loadFile: load) {
            (added, removed) = blockDiff(current: blocks, parent: PlanBlocks.split(parentText))
        }
        let edits = load(checkpointID, PlanLayers.userName).map(IntakeDetailProjection.hash) ?? ""
        return WireIntakePlan(checkpoint: checkpointID, roundName: BoardModel.name(stage: checkpoint.stage, round: checkpoint.round),
                              editsVersion: edits, markdown: markdown,
                              outline: outline(markdown: markdown, blocks: blocks, churn: churn, divergingSection: diverging),
                              notes: notes, added: added, removed: removed)
    }
}
