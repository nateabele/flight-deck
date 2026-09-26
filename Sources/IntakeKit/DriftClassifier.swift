import Foundation

public enum OpDrift: Equatable, Sendable {
    case holds
    case drifted(reason: String, suggested: DeliveryRating?)
    case impossible(reason: String)
}

public enum DriftClassifier {
    public static func classify(_ v: ValidatedChangeSet, current: GraphSnapshot) -> [OpDrift] {
        v.changeSet.ops.map { op in
            if case .addEdge(let from, let to, _) = op {
                var result: OpDrift = .holds
                for case .existing(let id) in [from, to] {
                    if current.beads[id] == nil {
                        result = .impossible(reason: "\(id) no longer exists")
                        break
                    }
                }
                return result
            }
            guard let id = op.existingTarget else { return .holds }
            guard let now = current.beads[id] else { return .impossible(reason: "\(id) no longer exists") }
            let pre: Precondition? = switch op {
                case .editBead(_, _, let p, _), .reopen(_, _, let p), .followUp(_, _, _, _, let p): p
                default: nil }
            guard let pre, pre != now.precondition else { return .holds }
            let who = now.assignee.map { " by \($0)" } ?? ""
            let reason = "\(id) was \(pre.status) at triage and is \(now.status)\(who) now"
            let existing: DeliveryRating? = if case .editBead(_, _, _, let d) = op { d?.rating } else { nil }
            return .drifted(reason: reason, suggested: now.status == "in_progress" ? (existing ?? .scopeChange) : nil)
        }
    }
}
