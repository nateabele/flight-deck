import Foundation

/// What a polish, fresh-eyes or dedup round hands back: its changes to the change set it was
/// given, keyed by each op's `index` in that change set — never the whole set again.
///
/// The whole set again was what these rounds returned until 2026-10-16, and it failed two ways
/// as plans grew. A 385-op change set is ~50k output tokens however few ops the round touched,
/// past what some models can write in one reply (Gemini 3.8 Flash under agy was cut off, asked
/// to continue three times and gave up after 16 minutes). And a model retyping 385 ops to change
/// ten can drop or reword any of the rest without saying so; validation checks the result is a
/// change set, not that the untouched ops came back untouched. Applied by FD, an op the patch
/// doesn't name is the previous op, byte for byte.
///
/// The checkpoint still stores the whole resulting change set: a later round reads one snapshot,
/// never a chain of patches.
public struct ChangeSetPatch: Codable, Equatable, Sendable {
    public struct Replacement: Codable, Equatable, Sendable {
        public var index: Int
        public var op: ChangeOp
        public init(index: Int, op: ChangeOp) { self.index = index; self.op = op }
    }

    /// A task merged away: every edge naming `from` names `to` instead. Wire spellings
    /// (`new:<tempId>` or an existing id), as edges carry them.
    public struct Redirect: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public var remove: [Int]
    public var replace: [Replacement]
    public var add: [ChangeOp]
    public var redirect: [Redirect]

    public init(remove: [Int] = [], replace: [Replacement] = [], add: [ChangeOp] = [], redirect: [Redirect] = []) {
        self.remove = remove; self.replace = replace; self.add = add; self.redirect = redirect
    }

    /// A patch that names an op the change set doesn't have, or names one twice. Its `message`
    /// goes back to the agent in the correction turn; `userMessage` is the human's.
    public enum Problem: Equatable, Sendable {
        case outOfRange(Int, count: Int)
        case namedTwice(Int)
        case selfRedirect(String)

        public var message: String {
            switch self {
            case .outOfRange(let i, let count):
                "index \(i) is not in the change set (its ops are numbered 0 to \(count - 1))"
            case .namedTwice(let i): "index \(i) is named more than once across `replace` and `remove`"
            case .selfRedirect(let ref): "a redirect points `\(ref)` at itself"
            }
        }

        public var userMessage: String {
            switch self {
            case .outOfRange: "the round changed a task the change set doesn't have"
            case .namedTwice: "the round changed the same task twice"
            case .selfRedirect: "the round merged a task into itself"
            }
        }
    }

    public struct Problems: Error, Equatable, Sendable { public let problems: [Problem] }

    /// `base` with this patch applied: every op in its place unless replaced or removed, the
    /// added ops after them, then the redirects applied to every edge. An edge a redirect turns
    /// into a self-edge, or into a copy of an earlier edge, is dropped — that is what merging two
    /// tasks that both depended on a third leaves behind, not something the agent should have
    /// to clean up by hand.
    public func apply(to base: ChangeSet) -> Result<ChangeSet, Problems> {
        var problems: [Problem] = []
        var named = Set<Int>()
        for i in remove + replace.map(\.index) {
            if !base.ops.indices.contains(i) { problems.append(.outOfRange(i, count: base.ops.count)) }
            else if !named.insert(i).inserted { problems.append(.namedTwice(i)) }
        }
        for r in redirect where r.from == r.to { problems.append(.selfRedirect(r.from)) }
        guard problems.isEmpty else { return .failure(Problems(problems: problems)) }

        let removed = Set(remove)
        let replacements = Dictionary(replace.map { ($0.index, $0.op) }, uniquingKeysWith: { first, _ in first })
        var ops: [ChangeOp] = base.ops.indices.compactMap { i in
            removed.contains(i) ? nil : replacements[i] ?? base.ops[i]
        }
        ops += add

        if !redirect.isEmpty {
            let map = Dictionary(redirect.map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
            func follow(_ ref: BeadRef) -> BeadRef {
                // One hop at a time to a fixed point, so a → b, b → c lands a on c; the visited
                // set stops a cycle the agent wrote from spinning.
                var wire = ref.wireValue, seen = Set<String>()
                while let next = map[wire], seen.insert(wire).inserted { wire = next }
                return BeadRef(parsing: wire)
            }
            var edges = Set<String>()
            ops = ops.compactMap { op in
                guard case .addEdge(let from, let to, let kind) = op else { return op }
                let (a, b) = (follow(from), follow(to))
                guard a != b, edges.insert("\(a.wireValue)|\(b.wireValue)|\(kind.rawValue)").inserted else { return nil }
                return .addEdge(from: a, to: b, kind: kind)
            }
        }
        return .success(ChangeSet(graphObservedAt: base.graphObservedAt, ops: ops))
    }

    /// The change set as the agent reads it: each op under its `index`, in the same
    /// `{index, op}` shape a `replace` entry takes, so the number to name is on the op itself
    /// rather than counted out of a several-thousand-line array.
    public static func numbered(_ base: ChangeSet) throws -> Data {
        let encoded = try JSONSerialization.jsonObject(with: try base.encoded()) as? [String: Any] ?? [:]
        let ops = (encoded["ops"] as? [Any] ?? []).enumerated().map { ["index": $0.offset, "op": $0.element] as [String: Any] }
        var out = encoded
        out["ops"] = ops
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

/// A polish-family round's reply: its patch and a one-line summary of what it did.
public struct ChangeSetPatchOutput: Codable, Sendable {
    public var patch: ChangeSetPatch
    public var summary: String
    public init(patch: ChangeSetPatch, summary: String) { self.patch = patch; self.summary = summary }
}
