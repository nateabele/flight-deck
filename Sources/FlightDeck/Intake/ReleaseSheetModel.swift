import IntakeKit

/// The release review sheet's words, apart from its layout (spec §10): what its Release button,
/// header caption and rows say. Pure, so the three counts are pinned together by a test rather
/// than by a render — they once disagreed on screen ("Release 7 Tasks" over "Release 2 tasks"
/// under "7 of 7 selected"), and rows named tasks by raw id (`fd-…-sfr → new:t1`).
struct ReleaseSheetModel {
    let ops: [ChangeOp]
    /// Left out of the release: dropped by hand, or impossible — `ReleaseSummary.skipped`, the
    /// same rule the summary line and `IntakeService.runRelease` apply.
    let skipped: Set<Int>
    /// Titles of the existing tasks the change set names, by id, from the live graph
    /// (`ReleaseReview.titles`).
    let titles: [String: String]

    init(ops: [ChangeOp], drift: [OpDrift], dropped: Set<Int>, titles: [String: String]) {
        self.ops = ops
        self.skipped = ReleaseSummary.skipped(drift: drift, dropped: dropped).filter { $0 < ops.count }
        self.titles = titles
    }

    /// What release will write, counted the way the summary line counts it.
    var counts: ReleaseCounts { ReleaseCounts(ops.indices.filter { !skipped.contains($0) }.map { ops[$0] }) }

    var releaseButton: String { UIText.releaseButton(counts) }

    /// Nil while nothing is left out: there is no selection to report, only drops.
    var header: String? { skipped.isEmpty ? nil : UIText.droppedCount(skipped.count) }

    /// A row's words, and the ids behind them for its help tag.
    struct Line: Equatable {
        let text: String
        let help: String
    }

    func line(_ op: ChangeOp) -> Line {
        switch op {
        case .createBead(let task):
            return Line(text: task.title, help: BeadRef.new(task.tempId).wireValue)
        case .followUp(let tempId, let of, let title, _, _):
            return Line(text: "\(title) · follow-up to \(name(.existing(of)))", help: "\(BeadRef.new(tempId).wireValue) · \(of)")
        case .editBead(let id, _, _, _):
            return Line(text: name(.existing(id)), help: id)
        case .reopen(let id, let reason, _):
            return Line(text: "Reopen \(name(.existing(id))): \(reason)", help: id)
        case .addEdge(let from, let to, let kind):
            // `from` depends on `to` (`ApplyPlanner`'s `.depend(dependent: from, dependency: to)`).
            let verb = switch kind {
            case .blocks: "waits on"
            case .related: "relates to"
            case .parentChild: "is part of"
            }
            return Line(text: "\(name(from)) \(verb) \(name(to))", help: "\(from.wireValue) → \(to.wireValue)")
        }
    }

    /// A task's title: the change set's own for one it creates, the live graph's for one that
    /// exists. The id only when the graph no longer knows it — better than an empty row.
    func name(_ ref: BeadRef) -> String {
        switch ref {
        case .existing(let id):
            return titles[id] ?? id
        case .new(let tempId):
            for op in ops {
                switch op {
                case .createBead(let task) where task.tempId == tempId: return task.title
                case .followUp(let t, _, let title, _, _) where t == tempId: return title
                default: continue
                }
            }
            return "new task"
        }
    }

    /// The same rule `ChangeSetValidator` uses for `ValidatedChangeSet.heldOpIndices` — an
    /// `addEdge` from an existing task to a new one blocks a live task the moment it's written,
    /// so it waits for release. Computed off the op because the sheet has no graph to validate.
    static func waitsForRelease(_ op: ChangeOp) -> Bool {
        if case .addEdge(let from, let to, _) = op, case .existing = from, case .new = to { return true }
        return false
    }

    /// What release will do about an in-progress task's holder, in words. No Flight Deck session
    /// means no way to message or take the task back — mail is the only channel, whatever the
    /// rating; the same gate `DeliveryPlanner.plan` applies.
    static func plannedDelivery(assignee: String, rating: DeliveryRating, reason: String, hasSession: Bool) -> String {
        guard hasSession else { return "\(assignee) has no Flight Deck session — mail only" }
        let op = ChangeOp.editBead(id: "", set: FieldSet(), pre: Precondition(status: "in_progress", assignee: assignee),
                                   delivery: Delivery(rating: rating, reason: reason))
        let actions = DeliveryPlanner.plan(ChangeSet(graphObservedAt: .distantPast, ops: [op]),
                                           ratings: [:], hasSession: { _ in true })
        return "\(assignee): " + actions.map(\.displayName).joined(separator: " + ")
    }
}
