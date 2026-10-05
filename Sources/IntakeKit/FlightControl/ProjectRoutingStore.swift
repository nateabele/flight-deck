import Foundation

/// What `.flightdeck/routing.json` holds right now.
public enum ProjectRulesLoad: Equatable, Sendable {
    case missing
    case loaded(RoutingRuleFile)
    case invalid(String)

    /// What routes. A missing or invalid file routes as no project rules (spec L3-R §8); the
    /// global list still applies.
    public var rules: [RoutingRule] {
        if case .loaded(let file) = self { return file.rules }
        return []
    }
}

public struct ProjectRulesUnwritable: Error, Equatable, Sendable {
    public let why: String
}

/// `.flightdeck/routing.json`: a project's rules, in the repo so they are versioned with it.
public struct ProjectRoutingStore: Sendable {
    public init() {}

    public static func fileURL(project: URL) -> URL {
        project.appendingPathComponent(".flightdeck", isDirectory: true).appendingPathComponent("routing.json")
    }

    public func load(project: URL) -> ProjectRulesLoad {
        let url = Self.fileURL(project: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .invalid("routing.json could not be read") }
        // `v` first, on its own: a newer file must be reported as newer, not as whatever
        // decoding error its new fields happen to trip.
        struct Version: Decodable { let v: Int? }
        if let v = (try? JSONDecoder().decode(Version.self, from: data))?.v, v > 1 {
            return .invalid("written by a newer Flight Deck (v\(v))")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return .loaded(try decoder.decode(RoutingRuleFile.self, from: data)) }
        catch { return .invalid("\(error)") }
    }

    /// Refuses while the current file is invalid. That file is the user's to fix — a merge
    /// conflict, a hand edit, a newer version — and replacing it with Settings' view of "no
    /// rules plus one" would destroy whatever they had.
    public func save(_ rules: [RoutingRule], project: URL) throws {
        if case .invalid(let why) = load(project: project) { throw ProjectRulesUnwritable(why: why) }
        let url = Self.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RoutingRuleFile(rules: rules)).write(to: url, options: .atomic)
    }
}
