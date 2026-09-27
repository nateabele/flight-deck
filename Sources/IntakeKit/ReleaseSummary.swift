import Foundation

/// The one-line footer the release-review sheet shows above its Release button (spec §8.4):
/// how much of a change set will actually be written, and how many notices go out because of
/// it. Pure — no graph, no live delivery — so it works from the same primitives
/// `IntakeService.reviewModel` already hands the sheet.
///
/// Takes `ops`/`heldOpIndices` rather than a `ValidatedChangeSet`: the review sheet has no
/// live `GraphSnapshot` to validate against (only `IntakeService` reads one, and it is
/// private), so it can never produce a `ValidatedChangeSet` itself. Held-ness needs no graph
/// either way — an `addEdge` from an existing bead to a new one is held by definition — so the
/// sheet recomputes `heldOpIndices` directly off the ops and hands both here.
public enum ReleaseSummary {
    /// - Parameters:
    ///   - ops: The change set's ops, e.g. `intake.changeSet!.ops`.
    ///   - heldOpIndices: Indices of `addEdge` ops from an existing bead to a new one —
    ///     `ValidatedChangeSet.heldOpIndices` when one is at hand, or the same rule applied
    ///     directly to `ops` when it isn't.
    ///   - drift: Parallel to `ops` — `DriftClassifier.classify`'s result.
    ///   - dropped: Ops the user dropped by hand.
    ///   - ratings: The *final* rating per edit-op index, user override already folded in —
    ///     forwarded to `DeliveryPlanner.plan` unchanged.
    ///   - hasSession: Whether a bead's holder has a live Flight Deck session.
    public static func text(
        _ ops: [ChangeOp],
        heldOpIndices: Set<Int>,
        drift: [OpDrift],
        dropped: Set<Int>,
        ratings: [Int: DeliveryRating],
        hasSession: (String) -> Bool
    ) -> String {
        // An impossible op's target bead is gone; it can never be written, same as one the
        // user dropped by hand. Both are excluded from every count below — release skips them
        // the same way `IntakeService.runRelease` does.
        let impossible = Set(drift.indices.filter { if case .impossible = drift[$0] { true } else { false } })
        let skip = dropped.union(impossible)

        let beads = ops.indices.filter { !skip.contains($0) && isCreate(ops[$0]) }.count
        let heldEdges = heldOpIndices.subtracting(skip).count

        var keptOps: [ChangeOp] = []
        var keptRatings: [Int: DeliveryRating] = [:]
        for (i, op) in ops.enumerated() where !skip.contains(i) {
            if let r = ratings[i] { keptRatings[keptOps.count] = r }
            keptOps.append(op)
        }
        // `DeliveryPlanner.plan` never reads `graphObservedAt`, so any date will do.
        let actions = DeliveryPlanner.plan(
            ChangeSet(graphObservedAt: .distantPast, ops: keptOps), ratings: keptRatings, hasSession: hasSession)

        var parts: [String] = []
        if beads > 0 { parts.append("\(beads) \(plural(beads, "bead"))") }
        if heldEdges > 0 { parts.append("\(heldEdges) held \(plural(heldEdges, "edge"))") }
        if !actions.isEmpty {
            // Ordered by first appearance in `actions`, not declaration order — the same
            // sequence a rating produces (`inject` before `mail`, `reclaim` before both).
            var order: [String] = []
            var counts: [String: Int] = [:]
            for a in actions {
                if counts[a.kindName] == nil { order.append(a.kindName) }
                counts[a.kindName, default: 0] += 1
            }
            let breakdown = order.map { "\(counts[$0]!) \($0)" }.joined(separator: ", ")
            parts.append("\(actions.count) \(plural(actions.count, "notice")) (\(breakdown))")
        }
        return parts.isEmpty ? "Nothing to release" : "Release " + parts.joined(separator: " · ")
    }

    private static func isCreate(_ op: ChangeOp) -> Bool {
        if case .createBead = op { return true }
        return false
    }

    private static func plural(_ n: Int, _ word: String) -> String { n == 1 ? word : word + "s" }
}
