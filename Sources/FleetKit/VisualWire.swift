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

/// One file of a visual revision that the phone can fetch, as the manifest lists it.
public struct WireVisualFile: Codable, Equatable, Sendable {
    /// Relative to the revision folder, `/`-separated (`export/index.html`).
    public var path: String
    public var size: Int64
    /// Lowercase hex SHA-256 of the file's bytes.
    public var sha256: String
    public init(path: String, size: Int64, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256 }
}

/// What the reader needs to lay a visual block out before its bytes arrive: which revision is
/// primary, which kinds exist, the other ways to see it, and the states a snapshot exists for.
///
/// **There is no archive.** A revision is a set of files, not one bundle. `files` lists every
/// file the revision serves (the manifest's `files`; for a comp, those under `r<n>/export/`).
/// The phone fetches them one at a time with `intake.visual.fetch` and `part: "file:<path>"`,
/// chunked by `offset` and `limit`; each reply's `WireFileChunk.path` is that relative path. It
/// checks the assembled file's SHA-256 against `sha256` and caches it by
/// `(id, revision, path)` indefinitely, since a revision never changes. A snapshot is fetched the
/// same way with `part: "snapshot@<state>-<size>"` (or plain `"snapshot"` for the default). The
/// total of a revision's files is at most `VisualLimits.maxBytes`.
public struct WireVisualRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The primary revision's number.
    public var revision: Int
    public var kinds: [String]
    public var alternates: [WireVisualAlternate]
    public var states: [String]
    /// The sizes snapshots exist for (`wide`, `narrow`), so the phone picks one before fetching.
    /// nil from a Mac that doesn't say.
    public var sizes: [String]?
    /// Width over height of the primary rendering, so the block takes its height before the
    /// bytes arrive. nil when unknown.
    public var aspect: Double?
    /// The files the phone may fetch for this revision. nil from a Mac that doesn't list them.
    public var files: [WireVisualFile]?

    public init(id: String, revision: Int, kinds: [String] = [], alternates: [WireVisualAlternate] = [],
                states: [String] = [], sizes: [String]? = nil, aspect: Double? = nil, files: [WireVisualFile]? = nil) {
        self.id = id; self.revision = revision; self.kinds = kinds
        self.alternates = alternates; self.states = states
        self.sizes = sizes; self.aspect = aspect; self.files = files
    }

    private enum Key: String, CodingKey { case id, revision, kinds, alternates, states, sizes, aspect, files }

    /// The lists default when absent, so a later Mac that leaves one out still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        revision = try c.decode(Int.self, forKey: .revision)
        kinds = try c.decodeIfPresent([String].self, forKey: .kinds) ?? []
        alternates = try c.decodeIfPresent([WireVisualAlternate].self, forKey: .alternates) ?? []
        states = try c.decodeIfPresent([String].self, forKey: .states) ?? []
        sizes = try c.decodeIfPresent([String].self, forKey: .sizes)
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect)
        files = try c.decodeIfPresent([WireVisualFile].self, forKey: .files)
    }
}

/// The `part` of `intake.visual.fetch`. A string on the wire, so a later part is a refusal from
/// the Mac, not a decode failure on it.
public enum WireVisualPart {
    /// The default state's snapshot at the default size.
    public static let snapshot = "snapshot"
    /// A named state's snapshot: `snapshot@<state>-<size>`.
    public static func snapshot(state: String, size: String) -> String { "snapshot@\(state)-\(size)" }
    /// One of the revision's listed files: `file:<relative path>`.
    public static func file(_ path: String) -> String { "file:" + path }
    /// The path inside a `file:` part, or nil for any other part or an empty path.
    public static func filePath(in part: String) -> String? {
        guard part.hasPrefix("file:"), part.count > 5 else { return nil }
        return String(part.dropFirst(5))
    }
}

public enum VisualLimits {
    /// The most a revision's fetch may add up to (§10). A larger one is refused `too_large`.
    public static let maxBytes = 10_485_760
}
