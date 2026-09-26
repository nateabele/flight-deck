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
        let ops = v.changeSet.ops.enumerated().filter { !skipping.contains($0.offset) }
        var creates: [ApplyStep] = [], edges: [ApplyStep] = [], edits: [ApplyStep] = []
        var reopens: [ApplyStep] = [], held: [ApplyStep] = []
        var knownPre: [String: Precondition] = [:]
        for (_, op) in ops {
            switch op {
            case .editBead(let id, _, let p, _), .reopen(let id, _, let p): knownPre[id] = p
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
                if v.heldOpIndices.contains(i), case .existing(let id) = from {
                    held += [.recheck(id: id, pre: knownPre[id]), .depend(dependent: from, dependency: to, kind: kind)]
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
