import Foundation

/// One axis benchmarks measure. Kinds are dynamic per project; dimensions are the stable ground
/// they are weighted against, so a rule compiled to a dimension routes kinds that did not exist
/// when it was written. L3-I owns changes to this list.
public struct Dimension: Codable, Hashable, Sendable {
    public var id: String
    public var summary: String
    public init(id: String, summary: String) { self.id = id; self.summary = summary }
}

public enum Dimensions {
    public static let all: [Dimension] = [
        Dimension(id: "agentic-coding", summary: "multi-step repo tasks end to end"),
        Dimension(id: "algorithmic-reasoning", summary: "hard algorithm and competitive-programming problems"),
        Dimension(id: "test-authoring", summary: "writing tests that are correct and catch bugs"),
        Dimension(id: "frontend-ui", summary: "web and UI work"),
        Dimension(id: "large-context-refactor", summary: "changes across many files and long context"),
        Dimension(id: "debugging", summary: "finding and fixing a failure from evidence"),
        Dimension(id: "docs-prose", summary: "technical writing"),
        Dimension(id: "tool-use-reliability", summary: "correct tool calls and terminal use"),
        Dimension(id: "speed", summary: "output tokens per second and time to first token"),
        Dimension(id: "cost-efficiency", summary: "inverse of cost per task"),
    ]
    public static let ids: Set<String> = Set(all.map(\.id))
    public static func isKnown(_ id: String) -> Bool { ids.contains(id) }
}
