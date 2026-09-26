import Foundation

public enum ValidationError: Equatable, Sendable {
    case unknownBead(String), undefinedTempId(String), duplicateTempId(String)
    case selfEdge(String), cycle, missingDelivery(String)
}
public struct ValidationErrors: Error, Equatable, Sendable { public let errors: [ValidationError] }

public struct ValidatedChangeSet: Equatable, Sendable {
    public let changeSet: ChangeSet
    /// Indices of `addEdge` ops whose dependent is an EXISTING bead and dependency a NEW one.
    /// Computed here, never taken from the agent: such an edge blocks a live bead the moment
    /// it is written (observed on br 0.6.0), so it waits for release.
    public let heldOpIndices: Set<Int>
}

public enum ChangeSetValidator {
    public static func validate(_ cs: ChangeSet, against graph: GraphSnapshot) -> Result<ValidatedChangeSet, ValidationErrors> {
        var errors: [ValidationError] = []
        var temps = Set<String>()
        for op in cs.ops {
            let t: String? = switch op { case .createBead(let b): b.tempId; case .followUp(let t, _, _, _, _): t; default: nil }
            if let t { if !temps.insert(t).inserted { errors.append(.duplicateTempId(t)) } }
        }
        func check(_ ref: BeadRef) {
            switch ref {
            case .existing(let id): if graph.beads[id] == nil { errors.append(.unknownBead(id)) }
            case .new(let t): if !temps.contains(t) { errors.append(.undefinedTempId(t)) }
            }
        }
        var held = Set<Int>()
        var blocking: [(String, String)] = graph.edges.map { ($0.dependent, $0.dependency) }
        for (i, op) in cs.ops.enumerated() {
            switch op {
            case .createBead: break
            case .addEdge(let from, let to, let kind):
                check(from); check(to)
                if from == to { errors.append(.selfEdge(from.wireValue)) }
                if case .existing = from, case .new = to { held.insert(i) }
                if kind != .related { blocking.append((from.wireValue, to.wireValue)) }
            case .editBead(let id, _, let pre, let delivery):
                check(.existing(id))
                if pre.status == "in_progress", delivery == nil { errors.append(.missingDelivery(id)) }
            case .reopen(let id, _, _): check(.existing(id))
            case .followUp(_, let of, _, _, _): check(.existing(of))
            }
        }
        if hasCycle(blocking) { errors.append(.cycle) }
        return errors.isEmpty ? .success(ValidatedChangeSet(changeSet: cs, heldOpIndices: held))
                              : .failure(ValidationErrors(errors: errors))
    }

    static func hasCycle(_ edges: [(String, String)]) -> Bool {
        var adj: [String: [String]] = [:]
        for (a, b) in edges { adj[a, default: []].append(b) }
        var state: [String: Int] = [:]           // 1 = on stack, 2 = done
        func visit(_ n: String) -> Bool {
            if state[n] == 1 { return true }
            if state[n] == 2 { return false }
            state[n] = 1
            for m in adj[n, default: []] where visit(m) { return true }
            state[n] = 2
            return false
        }
        return adj.keys.contains { visit($0) }
    }
}
