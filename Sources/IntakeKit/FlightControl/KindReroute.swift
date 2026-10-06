import Foundation

/// One open task and its `agent_context`.
public struct TaskContextRow: Equatable, Sendable {
    public var id: String
    public var agentContext: String?
    public init(id: String, agentContext: String?) { self.id = id; self.agentContext = agentContext }

    /// `br list --json` is an `{"issues": [...]}` envelope on br 0.6.0 (probed 2026-10-04). A bare
    /// array is accepted too, so a br that drops the envelope does not read as "no open tasks".
    public static func parse(brList data: Data) throws -> [TaskContextRow] {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let rows: [[String: Any]]
        if let envelope = json as? [String: Any], let issues = envelope["issues"] as? [[String: Any]] {
            rows = issues
        } else if let array = json as? [[String: Any]] {
            rows = array
        } else {
            throw TaskListUnreadable()
        }
        return rows.compactMap { row in
            (row["id"] as? String).map { TaskContextRow(id: $0, agentContext: row["agent_context"] as? String) }
        }
    }
}

public struct TaskListUnreadable: Error, Equatable, Sendable { public init() {} }

/// Which open tasks a kind change re-routes, and to what (spec L3-R §5: "when a kind is merged or
/// re-weighted, for the open tasks of that kind that are not pinned").
public enum KindReroute {
    public struct Change: Equatable, Sendable {
        public var id: String
        public var block: ExecutionBlock
        public init(id: String, block: ExecutionBlock) { self.id = id; self.block = block }
    }

    public struct Plan: Equatable, Sendable {
        public var changes: [Change] = []
        public var skippedPinned: [String] = []
        public var unroutable: [String: String] = [:]
        /// Blocks that do not decode. Reported, never repaired (L3-0 §4): re-routing over one would
        /// hide whatever wrote it.
        public var invalid: [String: String] = [:]
        public init() {}
    }

    /// `affected` is the kind that changed. A task is affected when its kind's merge chain passes
    /// through it — the kind itself, or a kind merged into it.
    public static func plan(rows: [TaskContextRow], affected: KindID, project: URL, kinds: [TaskKind],
                            router: any Router, catalogs: AdapterCatalogs, now: Date) -> Plan {
        var plan = Plan()
        for row in rows {
            switch ExecutionBlockCodec.decode(agentContext: row.agentContext) {
            case .failure(let error):
                plan.invalid[row.id] = error.message
            case .success(nil):
                continue
            case .success(let old?):
                guard KindChain.ids(from: old.kind, in: kinds).contains(affected) else { continue }
                if old.pinned { plan.skippedPinned.append(row.id); continue }
                let record = kinds.first { $0.id == old.kind }
                    ?? TaskKind(id: old.kind, name: old.kind.rawValue, description: "", dimensions: [:], origin: .planning, createdAt: now)
                let assignment = router.assign(kind: record, project: project, catalogs: catalogs, now: now)
                var block = assignment.block
                // Keeps the "unroutable: " prefix; the contract's own test decides what is unroutable.
                if assignment.isUnroutable { plan.unroutable[row.id] = block.source.reason; continue }
                if block.harness == old.harness, block.model == old.model, block.knobs == old.knobs, block.pool == old.pool { continue }
                block.kind = old.kind
                plan.changes.append(Change(id: row.id, block: block))
            }
        }
        return plan
    }
}
