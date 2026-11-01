import Foundation

public enum ValidationError: Equatable, Sendable {
    case unknownBead(String), undefinedTempId(String), duplicateTempId(String)
    case selfEdge(String), cycle, missingDelivery(String), preconditionMismatch(String)
}
public struct ValidationErrors: Error, Equatable, Sendable { public let errors: [ValidationError] }

extension ValidationError {
    /// One sentence an agent can act on — fed back verbatim by `Triage.correctionPrompt`, in the
    /// schema's own words (createTask, tempId, addEdge). Never shown to the human: that is
    /// `userMessage`.
    public var message: String {
        switch self {
        case .unknownBead(let id): "`\(id)` is not in the graph"
        case .undefinedTempId(let t): "`new:\(t)` is referenced, but no createTask or followUp op defines tempId `\(t)`"
        case .duplicateTempId(let t): "tempId `\(t)` is defined by more than one op"
        case .selfEdge(let ref): "an addEdge points `\(ref)` at itself"
        case .cycle: "the blocking edges, together with the graph's existing edges, form a cycle"
        case .missingDelivery(let id): "`\(id)` is in_progress, so its editTask needs a `delivery` rating"
        case .preconditionMismatch(let id): "the `pre` for `\(id)` does not match its current status and assignee in the graph"
        }
    }
    /// The same failure for the human, when the corrected change set fails too (spec §11): in
    /// tasks, never beads, and without the schema's op names (spec §2). Fed to the human as
    /// `message` once, it read "no createTask or followUp op defines tempId `t1`".
    public var userMessage: String {
        switch self {
        case .unknownBead(let id): "\(id) is not a task in the graph"
        case .undefinedTempId: "a dependency names a new task the plan never creates"
        case .duplicateTempId: "two new tasks were given the same name"
        case .selfEdge: "a task was made to depend on itself"
        case .cycle: "the new dependencies, with the graph's own, go round in a circle"
        case .missingDelivery(let id): "\(id) is in progress, so its edit needs a rating for how to tell its holder"
        case .preconditionMismatch(let id): "\(id)'s status or holder doesn't match the task graph"
        }
    }
}

public struct ValidatedChangeSet: Equatable, Sendable {
    public let changeSet: ChangeSet
    /// Indices of `addEdge` ops whose dependent is an EXISTING bead and dependency a NEW one.
    /// Computed here, never taken from the agent: such an edge blocks a live bead the moment
    /// it is written (observed on br 0.6.0), so it waits for release.
    public let heldOpIndices: Set<Int>
    /// What validation changed without failing, in the human's words (visual refs dropped).
    public var warnings: [String] = []
}

public enum ChangeSetValidator {
    /// `knownVisuals`: the ids of the visuals the plan has. nil skips the visual check, which is
    /// right for every caller that predates visuals. `Set()` is different: it means the plan
    /// has no visuals, so every `visualRefs` entry is dropped. `visualStates` names each known
    /// visual's states; a ref's state outside them is dropped. Drops are `warnings`, not errors.
    public static func validate(_ cs: ChangeSet, against graph: GraphSnapshot,
                                knownVisuals: Set<String>? = nil,
                                visualStates: [String: Set<String>] = [:]) -> Result<ValidatedChangeSet, ValidationErrors> {
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
        var ops = cs.ops
        var warnings: [String] = []
        var blocking: [(String, String)] = graph.edges.map { ($0.dependent, $0.dependency) }
        for (i, op) in cs.ops.enumerated() {
            switch op {
            case .createBead(var bead):
                // A ref to a visual the plan no longer has, or to a state its visual lacks, is
                // dropped with a warning, never a failure (V4 final review, A-I2, A-M5): a block
                // removed after encode must not block release or pause polish.
                if let known = knownVisuals, let refs = bead.visualRefs {
                    var kept: [VisualRef] = []
                    for var ref in refs {
                        guard known.contains(ref.visualID) else {
                            warnings.append("Task \u{201C}\(bead.title)\u{201D} no longer cites \(ref.visualID): the visual was removed")
                            continue
                        }
                        if let states = visualStates[ref.visualID] {
                            for state in ref.states where !states.contains(state) {
                                warnings.append("Task \u{201C}\(bead.title)\u{201D} cites state \(state) of \(ref.visualID), which the visual does not have; it was dropped")
                            }
                            ref.states = ref.states.filter(states.contains)
                        }
                        kept.append(ref)
                    }
                    if kept != refs { bead.visualRefs = kept; ops[i] = .createBead(bead) }
                }
            case .addEdge(let from, let to, let kind):
                check(from); check(to)
                if from == to { errors.append(.selfEdge(from.wireValue)) }
                if case .existing = from, case .new = to { held.insert(i) }
                if kind != .related { blocking.append((from.wireValue, to.wireValue)) }
            case .editBead(let id, _, let pre, let delivery):
                check(.existing(id))
                if let bead = graph.beads[id] {
                    if pre != bead.precondition { errors.append(.preconditionMismatch(id)) }
                    if bead.status == "in_progress", delivery == nil { errors.append(.missingDelivery(id)) }
                }
            case .reopen(let id, _, let pre):
                check(.existing(id))
                if let bead = graph.beads[id], pre != bead.precondition { errors.append(.preconditionMismatch(id)) }
            case .followUp(_, let of, _, _, let pre):
                check(.existing(of))
                if let bead = graph.beads[of], pre != bead.precondition { errors.append(.preconditionMismatch(of)) }
            }
        }
        if hasCycle(blocking) { errors.append(.cycle) }
        var checked = cs
        checked.ops = ops
        return errors.isEmpty ? .success(ValidatedChangeSet(changeSet: checked, heldOpIndices: held, warnings: warnings))
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
