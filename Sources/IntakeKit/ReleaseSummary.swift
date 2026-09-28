import Foundation

/// What a change set writes, counted the way the release review names its sections (spec §10):
/// a follow-up is a new task (of an existing one), a reopen is an edit to one, and every
/// `addEdge` is a dependency. One definition shared by the review body's count line, the release
/// sheet's summary line and its Release button — three counts of their own once disagreed on
/// screen ("Release 7 Tasks" over "Release 2 tasks": the button counted every op, the footer
/// only `createBead`, and neither said what the other meant).
public struct ReleaseCounts: Equatable, Sendable {
    public var newTasks = 0
    public var edits = 0
    public var dependencies = 0

    public init(_ ops: [ChangeOp]) {
        for op in ops {
            switch op {
            case .createBead, .followUp: newTasks += 1
            case .editBead, .reopen: edits += 1
            case .addEdge: dependencies += 1
            }
        }
    }

    public var isEmpty: Bool { newTasks + edits + dependencies == 0 }

    /// "3 new tasks · 2 edits · 1 dependency"; zero-count parts are left out, and nothing at all
    /// is the empty string — each caller says "nothing" in its own words.
    public var phrase: String {
        [(newTasks, "new task", "new tasks"), (edits, "edit", "edits"), (dependencies, "dependency", "dependencies")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
            .joined(separator: " · ")
    }
}

/// The one-line summary the release-review sheet shows above its Release button (spec §10):
/// what will actually be written, and how many notices go out because of it. Pure — no graph,
/// no live delivery — so it works from the same primitives `IntakeService.reviewModel` already
/// hands the sheet.
public enum ReleaseSummary {
    /// The ops release will skip: dropped by hand, or `.impossible` (the target task is gone, so
    /// it can never be written) — the same exclusion `IntakeService.runRelease` applies. Shared
    /// with the sheet's button and header, so what they count can't drift from this line.
    public static func skipped(drift: [OpDrift], dropped: Set<Int>) -> Set<Int> {
        dropped.union(drift.indices.filter { if case .impossible = drift[$0] { true } else { false } })
    }

    /// - Parameters:
    ///   - ops: The change set's ops, e.g. `intake.changeSet!.ops`.
    ///   - drift: Parallel to `ops` — `DriftClassifier.classify`'s result.
    ///   - dropped: Ops the user dropped by hand.
    ///   - ratings: The *final* rating per edit-op index, user override already folded in —
    ///     forwarded to `DeliveryPlanner.plan` unchanged.
    ///   - hasSession: Whether a task's holder has a live Flight Deck session.
    public static func text(
        _ ops: [ChangeOp],
        drift: [OpDrift],
        dropped: Set<Int>,
        ratings: [Int: DeliveryRating],
        hasSession: (String) -> Bool
    ) -> String {
        let skip = skipped(drift: drift, dropped: dropped)
        var keptOps: [ChangeOp] = []
        var keptRatings: [Int: DeliveryRating] = [:]
        for (i, op) in ops.enumerated() where !skip.contains(i) {
            if let r = ratings[i] { keptRatings[keptOps.count] = r }
            keptOps.append(op)
        }
        // `DeliveryPlanner.plan` never reads `graphObservedAt`, so any date will do.
        let actions = DeliveryPlanner.plan(
            ChangeSet(graphObservedAt: .distantPast, ops: keptOps), ratings: keptRatings, hasSession: hasSession)

        // "task", never "bead": this reaches the release-review sheet verbatim, and the
        // planning-UI redesign renames everything the human reads (spec §2) — the terminology
        // guard can't reach IntakeKit's own literals, so this one has to hold the line itself.
        var parts: [String] = []
        let counts = ReleaseCounts(keptOps)
        if !counts.isEmpty { parts.append(counts.phrase) }
        // A `reclaim` is a graph write IntakeDelivery makes on the holder's behalf, not a notice
        // sent *to* them, so it's excluded from both the count and the breakdown even though
        // `DeliveryPlanner` emits one alongside the invalidating inject+mail pair.
        let notices = actions.filter { $0.kindName != "reclaim" }
        if !notices.isEmpty {
            // Ordered by first appearance in `notices`, not declaration order — the same
            // sequence a rating produces (session message before mail).
            var order: [String] = []
            var counts: [String: Int] = [:]
            for a in notices {
                if counts[a.displayName] == nil { order.append(a.displayName) }
                counts[a.displayName, default: 0] += 1
            }
            // "mail" is a mass noun ("2 mail"); every other kind takes an s.
            let breakdown = order.map { name in
                let n = counts[name]!
                return "\(n) \(n == 1 || name == "mail" ? name : name + "s")"
            }.joined(separator: ", ")
            parts.append("\(notices.count) \(notices.count == 1 ? "notice" : "notices") (\(breakdown))")
        }
        return parts.isEmpty ? "Nothing to release" : parts.joined(separator: " · ")
    }
}
