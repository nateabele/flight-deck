import Foundation

/// Names an agent harness (`claude`, `codex`, `opencode`, …) by its adapter's raw id.
///
/// A string, not an enum, on purpose: IntakeKit cannot see the app's `AgentID`, and Level 3 must
/// route to any registered adapter — a new adapter becomes routable without touching this type.
public struct HarnessID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}

/// The L3 mapping for a planning harness (grok/gemini spec §3.1). Only claude and codex are
/// agent harnesses — they have an `AgentID`, an adapter, a routing catalog. grok and gemini are
/// planning-only: nil here means "not an agent harness", so no swarm task, capability index
/// entry or routing rule can ever target them. Faking a catalog for them would let the router
/// send a task to an agent Flight Deck cannot open a tab for.
public extension Harness {
    var agentHarnessID: HarnessID? {
        switch self {
        case .claude, .codex: HarnessID(rawValue)
        case .grok, .gemini: nil
        }
    }
}

/// Names a capacity pool (L3-U). A block names a pool, never an account, so rollover never
/// has to rewrite tasks.
public struct PoolID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}

/// Names a task kind in a project's kind registry.
public struct KindID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}
