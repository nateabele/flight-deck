import Foundation

public struct BeadSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var assignee: String?
    public var updatedAt: String?
    public var labels: [String]
    public init(id: String, title: String, status: String, assignee: String? = nil,
                updatedAt: String? = nil, labels: [String] = []) {
        self.id = id; self.title = title; self.status = status
        self.assignee = assignee; self.updatedAt = updatedAt; self.labels = labels
    }
    public var precondition: Precondition { Precondition(status: status, assignee: assignee) }
}

/// `dependent` depends on (is blocked by) `dependency` — `br dep add <dependent> <dependency>`,
/// and the `[dependent, dependency]` pairs of `br graph --json`.
public struct DepEdge: Hashable, Codable, Sendable {
    public var dependent: String
    public var dependency: String
    public init(dependent: String, dependency: String) { self.dependent = dependent; self.dependency = dependency }
}

/// Codable so triage can hand it to the agent as `graph.json` (Task 16).
public struct GraphSnapshot: Codable, Equatable, Sendable {
    public var beads: [String: BeadSnapshot]
    public var edges: Set<DepEdge>
    public init(beads: [String: BeadSnapshot] = [:], edges: Set<DepEdge> = []) { self.beads = beads; self.edges = edges }

    private struct ListEnvelope: Decodable {
        struct Issue: Decodable {
            let id: String; let title: String; let status: String
            let assignee: String?; let updated_at: String?; let labels: [String]?
        }
        let issues: [Issue]
    }
    private struct GraphEnvelope: Decodable {
        struct Component: Decodable { let edges: [[String]] }
        let components: [Component]
    }

    /// `list` is `br list --all --json` (closed included); `graph` is `br graph --all --json`.
    public static func decode(list: Data, graph: Data) throws -> GraphSnapshot {
        let issues = try JSONDecoder().decode(ListEnvelope.self, from: list).issues
        let comps = try JSONDecoder().decode(GraphEnvelope.self, from: graph).components
        var beads: [String: BeadSnapshot] = [:]
        for i in issues {
            beads[i.id] = BeadSnapshot(id: i.id, title: i.title, status: i.status,
                                       assignee: i.assignee, updatedAt: i.updated_at, labels: i.labels ?? [])
        }
        let edges = Set(comps.flatMap(\.edges).compactMap { pair -> DepEdge? in
            pair.count == 2 ? DepEdge(dependent: pair[0], dependency: pair[1]) : nil
        })
        return GraphSnapshot(beads: beads, edges: edges)
    }
}
