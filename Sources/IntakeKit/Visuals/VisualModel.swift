import Foundation

// The visual-block model (planning v2 §7, P2a V0). A visual's revisions live in
// `visuals/<visualID>/r<n>/` and never change once final; ThreadRunner is the only writer.
// Every shape here is a storage format from the day it lands: a field added later is optional,
// a reader tolerates a field it does not know, and a renamed key is a folder that no longer loads.

/// Names one visual. Codes as a bare string, so the id reads the same in the plan's
/// `fd-visual id=…` fence, as a folder name under `visuals/`, and in a wire field.
///
/// `RawRepresentable` over `String`, so `ThreadAnchor.visualID` (a plain `String`) converts both
/// ways without P1's anchor having to change.
///
/// **The id is a folder name, so it is checked.** It comes from a plan's text, and a plan is
/// agent- and human-written; `../../etc` must never become a path. Letters, digits, `-`, `_`
/// and `.` only, no leading dot, at most 64 characters.
public struct VisualID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func isValid(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 64, raw.first != "." else { return false }
        return raw.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ".")
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = VisualID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a usable visual id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func < (a: VisualID, b: VisualID) -> Bool { a.rawValue < b.rawValue }
}

/// One revision of one visual: `visuals/<id>/r<r>/`.
public struct RevisionRef: Codable, Hashable, Sendable {
    public var visualID: VisualID
    public var r: Int
    public init(visualID: VisualID, r: Int) { self.visualID = visualID; self.r = r }
}

/// How a pin on this revision finds its target (§7, "Pins"), in order of preference. A string,
/// so a scheme a later build adds reads as `.unknown` rather than failing the manifest.
public enum PinScheme: Hashable, Sendable, Codable {
    case node, element, position, unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.init(raw: raw)
    }
    init(raw: String) {
        switch raw {
        case "node": self = .node
        case "element": self = .element
        case "position": self = .position
        default: self = .unknown(raw)
        }
    }
    public var raw: String {
        switch self {
        case .node: "node"
        case .element: "element"
        case .position: "position"
        case .unknown(let s): s
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// Who made a revision: a thread, a round, or the human. `kind` is a string for the same reason
/// `PinScheme` is; `id` names the thread or round when there is one.
public struct VisualMaker: Codable, Hashable, Sendable {
    public var kind: String
    public var id: String?
    public init(kind: String, id: String? = nil) { self.kind = kind; self.id = id }
    public static let you = VisualMaker(kind: "you")
    public static func thread(_ id: ThreadID) -> VisualMaker { VisualMaker(kind: "thread", id: id.raw.uuidString) }
    public static func round(_ name: String) -> VisualMaker { VisualMaker(kind: "round", id: name) }
}

/// Another way to show the same thing, offered beside the primary: `{revision, kind, reason, by}`.
public struct VisualAlternate: Codable, Hashable, Sendable {
    public var revision: Int
    public var kind: String
    public var reason: String?
    public var by: VisualMaker?
    public init(revision: Int, kind: String, reason: String? = nil, by: VisualMaker? = nil) {
        self.revision = revision; self.kind = kind; self.reason = reason; self.by = by
    }
}

/// `manifest.json`: everything about a revision except its bytes.
public struct VisualManifest: Codable, Equatable, Sendable {
    public var provider: String
    public var providerVersion: String
    /// `mermaid`, `canvas`, `image`, …: open, because providers are (§9).
    public var kind: String
    public var title: String
    /// The file the renderer opens first, relative to the revision folder.
    public var entry: String
    /// Named states a snapshot exists for (`snapshot@<state>-<size>.png`); the first is the default.
    public var states: [String]
    public var sizes: [String]
    public var pins: PinScheme
    public var madeOnCheckpoint: Int
    public var madeBy: VisualMaker
    /// The revision this one was made from; nil for the first.
    public var parent: Int?
    public var alternates: [VisualAlternate]
    /// This revision is its visual's ★ primary representation.
    public var primary: Bool

    public init(provider: String, providerVersion: String, kind: String, title: String, entry: String,
                states: [String] = [], sizes: [String] = [], pins: PinScheme = .position,
                madeOnCheckpoint: Int, madeBy: VisualMaker, parent: Int? = nil,
                alternates: [VisualAlternate] = [], primary: Bool = false) {
        self.provider = provider; self.providerVersion = providerVersion; self.kind = kind
        self.title = title; self.entry = entry; self.states = states; self.sizes = sizes; self.pins = pins
        self.madeOnCheckpoint = madeOnCheckpoint; self.madeBy = madeBy; self.parent = parent
        self.alternates = alternates; self.primary = primary
    }

    private enum Key: String, CodingKey {
        case provider, providerVersion, kind, title, entry, states, sizes, pins
        case madeOnCheckpoint, madeBy, parent, alternates, primary
    }

    /// Lists default when absent, so a manifest a provider wrote with only the essentials loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        provider = try c.decode(String.self, forKey: .provider)
        providerVersion = try c.decode(String.self, forKey: .providerVersion)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        entry = try c.decode(String.self, forKey: .entry)
        states = try c.decodeIfPresent([String].self, forKey: .states) ?? []
        sizes = try c.decodeIfPresent([String].self, forKey: .sizes) ?? []
        pins = try c.decodeIfPresent(PinScheme.self, forKey: .pins) ?? .position
        madeOnCheckpoint = try c.decode(Int.self, forKey: .madeOnCheckpoint)
        madeBy = try c.decode(VisualMaker.self, forKey: .madeBy)
        parent = try c.decodeIfPresent(Int.self, forKey: .parent)
        alternates = try c.decodeIfPresent([VisualAlternate].self, forKey: .alternates) ?? []
        primary = try c.decodeIfPresent(Bool.self, forKey: .primary) ?? false
    }
}

/// A revision as read from disk.
public struct VisualRevision: Equatable, Sendable {
    public var id: VisualID
    public var r: Int
    public var manifest: VisualManifest
    public init(id: VisualID, r: Int, manifest: VisualManifest) { self.id = id; self.r = r; self.manifest = manifest }
    public var ref: RevisionRef { RevisionRef(visualID: id, r: r) }
}

/// `visuals/<id>/block.json`: the visual's representations in filmstrip order, with the ★ one.
/// Every plan checkpoint records the block states it saw, so an old plan shows its visuals as
/// they were then.
public struct BlockState: Codable, Equatable, Sendable {
    public var representations: [RevisionRef]
    public var primary: RevisionRef
    public init(representations: [RevisionRef], primary: RevisionRef) {
        self.representations = representations; self.primary = primary
    }
}

/// What a task should be built to match: a visual, and the states of it that bind the task
/// (`NewBead.visualRefs`; code writes the "Fidelity references" section from these, V-R3).
///
/// **`visualID` is a plain string, not a `VisualID`.** A change set comes from an agent, and one
/// bad id must reach `ChangeSetValidator` (`unknownVisual`, which is fed back as a correction)
/// rather than fail the whole change set's decode.
public struct VisualRef: Codable, Hashable, Sendable {
    public var visualID: String
    public var states: [String]
    public init(visualID: String, states: [String] = []) { self.visualID = visualID; self.states = states }

    private enum Key: String, CodingKey { case visualID, states }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        visualID = try c.decode(String.self, forKey: .visualID)
        states = try c.decodeIfPresent([String].self, forKey: .states) ?? []
    }
}
