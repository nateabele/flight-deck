import Foundation

public enum KindOrigin: String, Codable, Sendable { case seed, planning, user }

/// `merged` keeps the old id resolvable, so merging two kinds never rewrites a task.
public enum KindStatus: Equatable, Sendable, Codable {
    case active, proposed, merged(into: KindID)

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        switch s {
        case "active": self = .active
        case "proposed": self = .proposed
        case _ where s.hasPrefix("merged:") && s.count > 7: self = .merged(into: KindID(String(s.dropFirst(7))))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown kind status \(s)"))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .active: try c.encode("active")
        case .proposed: try c.encode("proposed")
        case .merged(let id): try c.encode("merged:\(id.rawValue)")
        }
    }
}

public enum KindValidationError: Error, Equatable, Sendable {
    case unknownDimension(String), weightOutOfRange(String, Double), emptyName
}

public struct TaskKind: Codable, Equatable, Sendable, Identifiable {
    public var id: KindID
    public var name: String
    public var description: String
    /// Dimension id → weight in 0...1. Missing dimensions weigh 0.
    public var dimensions: [String: Double]
    public var origin: KindOrigin
    public var status: KindStatus
    public var createdAt: Date

    public init(id: KindID, name: String, description: String, dimensions: [String: Double],
                origin: KindOrigin, status: KindStatus = .active, createdAt: Date) {
        self.id = id; self.name = name; self.description = description; self.dimensions = dimensions
        self.origin = origin; self.status = status; self.createdAt = createdAt
    }

    public func validate() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw KindValidationError.emptyName }
        for (dim, w) in dimensions.sorted(by: { $0.key < $1.key }) {
            guard Dimensions.isKnown(dim) else { throw KindValidationError.unknownDimension(dim) }
            guard (0...1).contains(w) else { throw KindValidationError.weightOutOfRange(dim, w) }
        }
    }
}

extension KindID {
    /// The id a proposed kind name maps to, so "Snapshot Tests" and "snapshot-tests" are one kind.
    public static func normalized(_ name: String) -> KindID {
        var out = ""; var pendingDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingDash && !out.isEmpty { out.append("-") }
                out.append(ch); pendingDash = false
            } else { pendingDash = true }
        }
        return KindID(out)
    }
}

public enum KindResolution {
    /// Follows `merged:` links to the live kind. Bounded by the registry size, so a cycle
    /// resolves to nil instead of spinning.
    public static func resolve(_ id: KindID, in kinds: [TaskKind]) -> TaskKind? {
        var current = id
        for _ in 0...kinds.count {
            guard let k = kinds.first(where: { $0.id == current }) else { return nil }
            guard case .merged(let next) = k.status else { return k }
            current = next
        }
        return nil
    }
}

/// `.flightdeck/kinds.json`.
public struct KindRegistryFile: Codable, Equatable, Sendable {
    public var v: Int
    public var kinds: [TaskKind]
    public init(v: Int = 1, kinds: [TaskKind]) { self.v = v; self.kinds = kinds }
}

public enum SeedKinds {
    public static func all(createdAt: Date) -> [TaskKind] {
        func k(_ id: String, _ name: String, _ d: String, _ w: [String: Double]) -> TaskKind {
            TaskKind(id: KindID(id), name: name, description: d, dimensions: w, origin: .seed, createdAt: createdAt)
        }
        return [
            k("implement-simple", "Simple implementation", "Small, well-specified code changes",
              ["agentic-coding": 0.5, "speed": 0.5, "cost-efficiency": 0.6]),
            k("implement-complex", "Complex implementation", "Multi-file features with design judgment",
              ["agentic-coding": 0.9, "large-context-refactor": 0.5, "tool-use-reliability": 0.5]),
            k("algorithm", "Algorithm", "Non-trivial algorithms and data structures",
              ["algorithmic-reasoning": 0.9, "agentic-coding": 0.3]),
            k("tests", "Tests", "Unit and integration tests",
              ["test-authoring": 0.9, "agentic-coding": 0.4]),
            k("refactor", "Refactor", "Behavior-preserving restructuring",
              ["large-context-refactor": 0.9, "agentic-coding": 0.5]),
            k("docs", "Docs", "Documentation and prose",
              ["docs-prose": 0.9, "cost-efficiency": 0.4]),
            k("investigate", "Investigate", "Find a root cause from evidence",
              ["debugging": 0.9, "tool-use-reliability": 0.5]),
            k("review", "Review", "Review code or a plan for defects",
              ["debugging": 0.6, "large-context-refactor": 0.5, "algorithmic-reasoning": 0.4]),
            k("ui", "UI", "User-interface work",
              ["frontend-ui": 0.9, "agentic-coding": 0.4]),
        ]
    }
}
