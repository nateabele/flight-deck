import Foundation

// Visual blocks on the wire (planning v2 §10, P2a V0). Ids are plain strings here: FleetKit does
// not know IntakeKit's `VisualID`, and the phone only echoes back what the Mac sent.

/// Another representation of the same visual, offered beside the primary.
public struct WireVisualAlternate: Codable, Equatable, Sendable {
    public var revision: Int
    public var kind: String
    public var reason: String?
    public init(revision: Int, kind: String, reason: String? = nil) {
        self.revision = revision; self.kind = kind; self.reason = reason
    }
}

/// What the reader needs to lay a visual block out before its bytes arrive: which revision is
/// primary, which kinds exist, the other ways to see it, and the states a snapshot exists for.
/// The bytes come from `intake.visual.fetch`, and a revision never changes, so the phone caches
/// them by `(id, revision)` indefinitely.
public struct WireVisualRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The primary revision's number.
    public var revision: Int
    public var kinds: [String]
    public var alternates: [WireVisualAlternate]
    public var states: [String]

    public init(id: String, revision: Int, kinds: [String] = [], alternates: [WireVisualAlternate] = [],
                states: [String] = []) {
        self.id = id; self.revision = revision; self.kinds = kinds
        self.alternates = alternates; self.states = states
    }

    private enum Key: String, CodingKey { case id, revision, kinds, alternates, states }

    /// The lists default when absent, so a later Mac that leaves one out still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        revision = try c.decode(Int.self, forKey: .revision)
        kinds = try c.decodeIfPresent([String].self, forKey: .kinds) ?? []
        alternates = try c.decodeIfPresent([WireVisualAlternate].self, forKey: .alternates) ?? []
        states = try c.decodeIfPresent([String].self, forKey: .states) ?? []
    }
}

/// The `part` of `intake.visual.fetch`. A string on the wire, so a later part is a refusal from
/// the Mac, not a decode failure on it.
public enum WireVisualPart {
    /// The default state's snapshot at the default size.
    public static let snapshot = "snapshot"
    /// A named state's snapshot: `snapshot@<state>-<size>`.
    public static func snapshot(state: String, size: String) -> String { "snapshot@\(state)-\(size)" }
    /// The revision's files, for the live view.
    public static let bundle = "bundle"
}

public enum VisualLimits {
    /// The most a revision's fetch may add up to (§10). A larger one is refused `too_large`.
    public static let maxBytes = 10_485_760
}
