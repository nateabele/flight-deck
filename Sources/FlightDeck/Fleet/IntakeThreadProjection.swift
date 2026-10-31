import FleetKit
import Foundation
import IntakeKit

/// Ask threads as the phone reads them (spec §10). Every function takes the reader and the
/// plan's blocks, so it is pure: Stream A's on-disk store, or a fake, supplies the threads.
/// Block indices are `PlanBlocks.split` of the plan the phone is reading, the same function
/// the phone runs, so an index names the same block on both ends.
enum IntakeThreadProjection {
    /// The longest excerpt a card shows; the full reply is one `intake.thread.get` away.
    static let excerptLimit = 140

    /// The block whose rendered text contains `text`, or nil: a passage no block holds any more
    /// stays unplaced rather than pinned to a near miss, as notes do (`IntakePlanProjection.locate`).
    static func block(of text: String?, in blocks: PlanBlocks) -> Int? {
        guard let text else { return nil }
        let needle = IntakePlanProjection.normalized(text)
        guard !needle.isEmpty else { return nil }
        return blocks.blocks.first { IntakePlanProjection.normalized($0.text).contains(needle) }?.index
    }

    /// Diffs the reader still needs a decision on. A decided diff is history; a stale one stays
    /// listed so the phone can say it could not be applied.
    private static func isLive(_ d: ThreadDiff) -> Bool { d.state == .pending || d.state == .stale }

    /// The unanswered questions: the newest turn's `askQuestion` actions. An answer starts a
    /// later turn, so a question on an older turn is always answered.
    static func openQuestions(_ turns: [ThreadTurn]) -> [StructuredQuestion] {
        guard let last = turns.max(by: { $0.seq < $1.seq }) else { return [] }
        return last.actions.compactMap { if case .askQuestion(let q) = $0 { q } else { nil } }
    }

    static func excerpt(_ turns: [ThreadTurn]) -> String? {
        guard let reply = turns.sorted(by: { $0.seq > $1.seq }).lazy.compactMap({ $0.reply }).first(where: { !$0.isEmpty })
        else { return nil }
        let line = reply.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? reply
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > excerptLimit ? String(trimmed.prefix(excerptLimit)) + "…" : trimmed
    }

    static func summary(_ record: ThreadRecord, reader: any ThreadStoreReading, blocks: PlanBlocks) -> WireThreadSummary {
        let turns = reader.turns(record.id)
        let anchor = record.anchor.note.map {
            WireThreadAnchor(checkpoint: $0.checkpoint, block: block(of: $0.quote, in: blocks), quote: $0.quote, section: $0.section)
        }
        return WireThreadSummary(
            id: record.id.raw, title: record.title, anchor: anchor, status: record.status.rawValue,
            counts: WireThreadCounts(turns: turns.count, pendingDiffs: reader.diffs(record.id).filter(isLive).count,
                                     openQuestions: openQuestions(turns).count),
            excerpt: excerpt(turns))
    }

    static func threads(reader: any ThreadStoreReading, blocks: PlanBlocks) -> [WireThreadSummary] {
        reader.threads().map { summary($0, reader: reader, blocks: blocks) }
    }

    static func pendingDiff(_ d: ThreadDiff, blocks: PlanBlocks) -> WirePendingDiff {
        WirePendingDiff(id: d.id, thread: d.thread.raw, checkpoint: d.checkpoint, blockIndex: block(of: d.old, in: blocks),
                        old: d.old, new: d.new, state: d.state.rawValue)
    }

    static func pendingDiffs(reader: any ThreadStoreReading, blocks: PlanBlocks) -> [WirePendingDiff] {
        reader.threads().flatMap { reader.diffs($0.id).filter(isLive).map { pendingDiff($0, blocks: blocks) } }
    }

    /// Threads waiting on the person: the list row's badge.
    static func needingYou(reader: any ThreadStoreReading) -> Int {
        reader.threads().filter { $0.status == .needsYou }.count
    }

    static func wireTurn(_ t: ThreadTurn, diffs: [ThreadDiff]) -> WireThreadTurn {
        let questions = t.actions.compactMap { if case .askQuestion(let q) = $0 { IntakeDetailProjection.wireQuestion(q) } else { nil } }
        let linked = diffs.filter { $0.turn == t.seq }.map(\.id)
        return WireThreadTurn(
            seq: t.seq, messageID: t.messageID, you: t.you,
            answers: t.answers.map { $0.map { WireStructuredAnswer(questionID: $0.questionID, selected: $0.selected, other: $0.other) } },
            reply: t.reply, decision: t.decision, questions: questions.isEmpty ? nil : questions,
            diffs: linked.isEmpty ? nil : linked, errors: t.errors, checkpoint: t.checkpoint,
            startedAt: t.startedAt, endedAt: t.endedAt)
    }

    /// One thread's turns after `since` (all of them when nil), with every diff it proposed
    /// whatever its state: the turn lists the ids, and the page carries the bodies.
    static func page(reader: any ThreadStoreReading, thread: ThreadID, since: Int?, blocks: PlanBlocks) -> WireThreadPage? {
        guard let record = reader.threads().first(where: { $0.id == thread }) else { return nil }
        let diffs = reader.diffs(thread)
        let turns = reader.turns(thread).filter { $0.seq > (since ?? 0) }.sorted { $0.seq < $1.seq }
        return WireThreadPage(thread: summary(record, reader: reader, blocks: blocks),
                              turns: turns.map { wireTurn($0, diffs: diffs) },
                              diffs: diffs.map { pendingDiff($0, blocks: blocks) })
    }

    /// Fills `plan`'s thread fields. Left nil when this Mac reads no threads, so an old phone and
    /// a Mac without threads see the same bytes as before.
    @MainActor
    static func fill(_ plan: inout WireIntakePlan, intake id: UUID, blocks: PlanBlocks, service: IntakeService) {
        guard let reader = service.threadReader(id) else { return }
        plan.threads = threads(reader: reader, blocks: blocks)
        plan.pendingDiffs = pendingDiffs(reader: reader, blocks: blocks)
    }

    /// nil rather than 0: the phone shows a badge only for a count, and a Mac without threads
    /// sends none.
    @MainActor
    static func needingYou(intake id: UUID, service: IntakeService) -> Int? {
        guard let reader = service.threadReader(id) else { return nil }
        let n = needingYou(reader: reader)
        return n > 0 ? n : nil
    }
}
