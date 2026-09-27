import Foundation

public enum ApplyStep: Equatable, Sendable {
    case create(NewBead)
    case depend(dependent: BeadRef, dependency: BeadRef, kind: EdgeKind)
    /// Re-read `id` right before writing to it; abort the release if it no longer matches.
    /// `pre == nil` means "must still exist" only.
    case recheck(id: String, pre: Precondition?)
    case update(id: String, set: FieldSet)
    case reopen(id: String, reason: String)
}

public enum ApplyPlanner {
    public static func plan(_ v: ValidatedChangeSet, skipping: Set<Int>) -> [ApplyStep] {
        // Collect tempIds from skipped createBead and followUp ops
        var skippedTempIds = Set<String>()
        for (i, op) in v.changeSet.ops.enumerated() {
            if skipping.contains(i) {
                switch op {
                case .createBead(let b): skippedTempIds.insert(b.tempId)
                case .followUp(let t, _, _, _, _): skippedTempIds.insert(t)
                default: break
                }
            }
        }

        let ops = v.changeSet.ops.enumerated().filter { !skipping.contains($0.offset) }
        var creates: [ApplyStep] = [], edges: [ApplyStep] = [], edits: [ApplyStep] = []
        var reopens: [ApplyStep] = [], held: [ApplyStep] = []
        // What a held edge's recheck may demand of its `from` bead. Held edges run LAST, after
        // every edit and reopen: an edit leaves status and assignee alone, so its `pre` still
        // describes the bead then; a reopen does not — it has just set the bead open itself,
        // so demanding its triage-time `closed` would fail FD's own write on FD's own check
        // and stop every "reopen X, X blocked by new:n1" release one step short. A reopened
        // bead is therefore rechecked for existence only, whether or not it was also edited
        // and in whichever order those two ops were listed.
        var editPre: [String: Precondition] = [:], reopened = Set<String>()
        for (_, op) in ops {
            switch op {
            case .editBead(let id, _, let p, _): editPre[id] = p
            case .reopen(let id, _, _): reopened.insert(id)
            default: break
            }
        }
        for (i, op) in ops {
            switch op {
            case .createBead(let b): creates.append(.create(b))
            case .followUp(let t, let of, let title, let d, _):
                creates.append(.create(NewBead(tempId: t, title: title, description: d)))
                edges.append(.depend(dependent: .new(t), dependency: .existing(of), kind: .related))
            case .addEdge(let from, let to, let kind):
                // Skip edges that reference skipped tempIds
                let fromSkipped = if case .new(let t) = from { skippedTempIds.contains(t) } else { false }
                let toSkipped = if case .new(let t) = to { skippedTempIds.contains(t) } else { false }
                if fromSkipped || toSkipped { break }

                if v.heldOpIndices.contains(i), case .existing(let id) = from {
                    held += [.recheck(id: id, pre: reopened.contains(id) ? nil : editPre[id]), .depend(dependent: from, dependency: to, kind: kind)]
                } else {
                    edges.append(.depend(dependent: from, dependency: to, kind: kind))
                }
            case .editBead(let id, let set, let p, _): edits += [.recheck(id: id, pre: p), .update(id: id, set: set)]
            case .reopen(let id, let r, let p): reopens += [.recheck(id: id, pre: p), .reopen(id: id, reason: r)]
            }
        }
        return creates + edges + edits + reopens + held
    }
}
