import Foundation

// Visual blocks on the wire (planning v2 §10, P2a V0). Ids are plain strings here: FleetKit does
// not know IntakeKit's `VisualID`, and the phone only echoes back what the Mac sent.

/// Another representation of the same visual, offered beside the primary.
public struct WireVisualAlternate: Codable, Equatable, Sendable {
    public var revision: Int
    public var kind: String
    public var reason: String?
    /// The files the phone may fetch for this revision, as `WireVisualRef.files` lists them for the
    /// primary. nil from a Mac that doesn't list them: the alternate is then only a chip.
    public var files: [WireVisualFile]?
    public init(revision: Int, kind: String, reason: String? = nil, files: [WireVisualFile]? = nil) {
        self.revision = revision; self.kind = kind; self.reason = reason; self.files = files
    }

    private enum Key: String, CodingKey { case revision, kind, reason, files }

    /// `files` is additive: a payload written before it existed decodes with nil.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        revision = try c.decode(Int.self, forKey: .revision)
        kind = try c.decode(String.self, forKey: .kind)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        files = try c.decodeIfPresent([WireVisualFile].self, forKey: .files)
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

/// The width a snapshot or page of a named size is drawn at, in points. The Mac's table
/// (`IntakeKit.VisualSize.width`, which the Mac draws snapshots with); a hosted test pins the two
/// together. A name is `phone`, `mac`, a bare width (`640`) or `<w>x<h>`; anything else is the
/// default. Clamped.
public enum VisualSizeWidth {
    public static let defaultWidth = 760
    public static let range = 200...2400

    public static func width(_ name: String) -> Int {
        let named: [String: Int] = ["default": defaultWidth, "phone": 390, "compact": 390, "tablet": 768,
                                    "mac": 1024, "desktop": 1280, "wide": 1280]
        if let w = named[name.lowercased()] { return w }
        let head = name.lowercased().split(separator: "x", maxSplits: 1).first.map(String.init) ?? ""
        guard let w = Int(head) else { return defaultWidth }
        return min(max(w, range.lowerBound), range.upperBound)
    }
}
