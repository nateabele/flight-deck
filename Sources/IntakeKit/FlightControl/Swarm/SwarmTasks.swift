import Foundation

/// A task the swarm may claim: `br ready`'s row joined to its scheduler rank and its block.
public struct ReadyTask: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var priority: Int
    public var rank: Int?
    public var agentContext: String?
    public init(id: String, title: String, priority: Int, rank: Int?, agentContext: String?) {
        self.id = id; self.title = title; self.priority = priority; self.rank = rank; self.agentContext = agentContext
    }
    /// Decoded on demand, so an invalid block is reported per task and never repaired (L3-0 §4).
    public var block: Result<ExecutionBlock?, ExecutionBlockError> { ExecutionBlockCodec.decode(agentContext: agentContext) }
}

public struct TaskDetail: Equatable, Sendable {
    public var id: String
    public var title: String
    public var description: String
    public var acceptance: String
    public var status: String
    public var assignee: String?
    public init(id: String, title: String, description: String, acceptance: String, status: String, assignee: String?) {
        self.id = id; self.title = title; self.description = description; self.acceptance = acceptance
        self.status = status; self.assignee = assignee
    }
}

public struct TaskStatusReading: Equatable, Sendable {
    public var status: String
    public var assignee: String?
    public init(status: String, assignee: String?) { self.status = status; self.assignee = assignee }
}

/// br's claim is atomic (probed: a second claim fails `VALIDATION_FAILED`, `retryable: true`).
/// `failed` is every other non-zero exit; the controller treats it like a conflict for this tick.
public enum ClaimOutcome: Equatable, Sendable { case claimed, conflict, failed(String) }

public struct ReadyRow: Equatable, Sendable {
    public var id: String
    public var title: String
    public var priority: Int
    public init(id: String, title: String, priority: Int) { self.id = id; self.title = title; self.priority = priority }
}

public enum SwarmTaskDecoding {
    private static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// The rows of an envelope `{issues:[…]}` or a bare array — `br ready` is bare, `br list` is
    /// wrapped (observe-command-shapes notes), and the L3-0 fixture is bare.
    private static func rows(_ data: Data) -> [[String: Any]]? {
        switch json(data) {
        case let array as [[String: Any]]: array
        case let object as [String: Any]: object["issues"] as? [[String: Any]]
        default: nil
        }
    }

    public static func readyRows(_ data: Data) -> [ReadyRow]? {
        rows(data)?.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return ReadyRow(id: id, title: row["title"] as? String ?? id, priority: row["priority"] as? Int ?? 2)
        }
    }

    /// `br scheduler --format json`: `{schema:"br.scheduler.v1", recommendations:[{rank, issue:{id}}]}`.
    /// A different schema major is refused (nil) so the caller falls back to priority order rather
    /// than trusting fields it does not know.
    public static func schedulerRanks(_ data: Data) -> [String: Int]? {
        guard let object = json(data) as? [String: Any] else { return nil }
        if let schema = object["schema"] as? String, !schema.hasPrefix("br.scheduler.v1") { return nil }
        guard let recs = object["recommendations"] as? [[String: Any]] else { return nil }
        var ranks: [String: Int] = [:]
        for (index, rec) in recs.enumerated() {
            guard let issue = rec["issue"] as? [String: Any], let id = issue["id"] as? String else { continue }
            ranks[id] = rec["rank"] as? Int ?? index + 1
        }
        return ranks
    }

    /// Task id → its raw `agent_context` string. Rows without one have no entry.
    public static func listContexts(_ data: Data) -> [String: String]? {
        guard let rows = rows(data) else { return nil }
        var out: [String: String] = [:]
        for row in rows {
            if let id = row["id"] as? String, let ctx = row["agent_context"] as? String { out[id] = ctx }
        }
        return out
    }

    public static func detail(_ data: Data) -> TaskDetail? {
        let object: [String: Any]?
        switch json(data) {
        case let array as [[String: Any]]: object = array.first
        case let single as [String: Any]: object = (single["issue"] as? [String: Any]) ?? single
        default: object = nil
        }
        guard let o = object, let id = o["id"] as? String else { return nil }
        return TaskDetail(id: id, title: o["title"] as? String ?? id,
                          description: o["description"] as? String ?? "",
                          acceptance: o["acceptance_criteria"] as? String ?? "",
                          status: o["status"] as? String ?? "unknown",
                          assignee: (o["assignee"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Ready rows in scheduler order. Only READY rows are ever returned: the scheduler ranks the
    /// whole project, and a ranked task that is not ready (blocked, claimed) must never be claimed.
    /// Unranked rows follow, by priority then id, so the order is total and stable.
    public static func join(ready: [ReadyRow], ranks: [String: Int], contexts: [String: String]) -> [ReadyTask] {
        ready.map { ReadyTask(id: $0.id, title: $0.title, priority: $0.priority, rank: ranks[$0.id], agentContext: contexts[$0.id]) }
            .sorted { a, b in
                switch (a.rank, b.rank) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return (a.priority, a.id) < (b.priority, b.id)
                }
            }
    }

    public static func claimOutcome(exitCode: Int32, stdout: String) -> ClaimOutcome {
        if exitCode == 0 { return .claimed }
        if stdout.contains("VALIDATION_FAILED") { return .conflict }
        let first = stdout.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "(no output)"
        return .failed("exit \(exitCode): \(first)")
    }
}
