import Foundation

/// A snapshot's file stamp: `2026-10-04T060000Z`.
///
/// UTC so a timezone change (travel, a DST edge) can never reorder which snapshot is newest —
/// "newest" is decided by sorting these strings. Date AND time so two refreshes on one day (or
/// a refresh and an alias rescore) never overwrite each other. No colons, so Finder shows the
/// name as written instead of turning `:` into `/`. A fresh formatter per call: `DateFormatter`
/// is not `Sendable`, so IntakeKit cannot keep one in a static.
public enum IndexStamp {
    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return f
    }

    public static func string(_ date: Date) -> String { formatter().string(from: date) }

    /// Nil unless `stamp` is exactly what `string` would write — so `config.json` or a
    /// hand-made `2026-10-04.json` is never mistaken for a snapshot.
    public static func date(_ stamp: String) -> Date? {
        let f = formatter()
        guard let d = f.date(from: stamp), f.string(from: d) == stamp else { return nil }
        return d
    }
}

/// What one refresh got from one source. `stale` means the rows are the PREVIOUS snapshot's,
/// carried forward because this refresh could not read the source (`error` says why) — the
/// index keeps scoring with them rather than dropping a model's data on one bad run.
public struct SourceResult: Codable, Equatable, Sendable {
    public var sourceID: String
    public var rows: [AcceptedRow]
    public var rejected: [RejectedRow]
    public var stale: Bool
    public var error: String?
    /// When `rows` were read. A carried-forward result keeps the original read time.
    public var refreshedAt: Date?
    public var tokens: Int
    public init(sourceID: String, rows: [AcceptedRow], rejected: [RejectedRow] = [], stale: Bool = false,
                error: String? = nil, refreshedAt: Date?, tokens: Int = 0) {
        self.sourceID = sourceID; self.rows = rows; self.rejected = rejected; self.stale = stale
        self.error = error; self.refreshedAt = refreshedAt; self.tokens = tokens
    }
}

public enum ScoreOrigin: String, Codable, Sendable { case computed, manual, inherited }

/// One model's score on one dimension, 0...1, with the share of that dimension's source weight
/// that stood behind it. Absent — never zero — when nothing did.
public struct DimensionScore: Codable, Equatable, Sendable {
    public var score: Double
    public var confidence: Double
    public var origin: ScoreOrigin
    public var inheritedFrom: ModelRef?
    /// Source ids whose rows produced this score.
    public var sources: [String]
    public init(score: Double, confidence: Double, origin: ScoreOrigin = .computed,
                inheritedFrom: ModelRef? = nil, sources: [String] = []) {
        self.score = score; self.confidence = confidence; self.origin = origin
        self.inheritedFrom = inheritedFrom; self.sources = sources
    }
}

public struct ModelScores: Codable, Equatable, Sendable {
    public var model: ModelRef
    public var dimensions: [String: DimensionScore]
    public init(model: ModelRef, dimensions: [String: DimensionScore]) { self.model = model; self.dimensions = dimensions }
}

/// One refresh's result, as written to `capability-index/<stamp>.json`: raw rows per source,
/// the confirmed aliases they were scored with, the computed scores, and the names nobody has
/// mapped. Manual and inherited scores are NOT stored here — they are overlaid live from the
/// config (`CapabilityScoring.overlay`), so editing one never needs a refresh and the diff
/// between two snapshots shows only what the benchmarks moved.
public struct IndexSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var v: Int
    public var createdAt: Date
    public var sources: [SourceResult]
    public var aliases: [AliasEntry]
    public var scores: [ModelScores]
    public var unmapped: [UnmappedName]

    public init(v: Int = IndexSnapshot.currentVersion, createdAt: Date, sources: [SourceResult],
                aliases: [AliasEntry], scores: [ModelScores], unmapped: [UnmappedName]) {
        self.v = v; self.createdAt = createdAt; self.sources = sources
        self.aliases = aliases; self.scores = scores; self.unmapped = unmapped
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Hand-entered scores for a model no benchmark lists (a local model). A hand score has
/// confidence 1 and is labelled manual. `inheritFrom` copies a base model's scores at
/// `discount` for every dimension that has neither a hand score nor a computed one.
public struct ManualModelScores: Codable, Equatable, Sendable {
    public static let defaultDiscount = 0.85
    public var model: ModelRef
    public var dimensions: [String: Double]
    public var inheritFrom: ModelRef?
    public var discount: Double
    public init(model: ModelRef, dimensions: [String: Double], inheritFrom: ModelRef? = nil,
                discount: Double = ManualModelScores.defaultDiscount) {
        self.model = model; self.dimensions = dimensions; self.inheritFrom = inheritFrom; self.discount = discount
    }
}

/// Decodes one hand-entered score, or nothing when it names an agent this build cannot read.
private struct LossyManualScores: Decodable {
    let value: ManualModelScores?
    init(from decoder: Decoder) throws { value = try? ManualModelScores(from: decoder) }
}

/// The refresh agent. claude only in v1: it is the harness whose web tools and `--restricted`
/// isolation were probed (claude 2.1.289 `--help`: `--restricted` removes WebFetch "unless
/// --tools names them").
public struct IndexAgentSettings: Codable, Equatable, Sendable {
    public var model: String
    public var effort: String
    /// Input plus output tokens for one whole refresh, all sources together.
    public var tokenCap: Int
    public init(model: String, effort: String, tokenCap: Int) { self.model = model; self.effort = effort; self.tokenCap = tokenCap }
    public static let standard = IndexAgentSettings(model: "sonnet", effort: "medium", tokenCap: 1_500_000)
}

/// `capability-index/config.json`: everything the user edits in Settings.
public struct IndexConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var v: Int
    public var sources: [IndexSource]
    public var aliases: AliasTable
    public var manual: [ManualModelScores]
    public var agent: IndexAgentSettings
    /// Set at the START of every refresh attempt, success or failure. The weekly check reads it,
    /// so a run that fails waits a week instead of retrying on every clock beat.
    public var lastRefreshAttemptAt: Date?

    public init(v: Int = IndexConfig.currentVersion, sources: [IndexSource], aliases: AliasTable,
                manual: [ManualModelScores], agent: IndexAgentSettings, lastRefreshAttemptAt: Date?) {
        self.v = v; self.sources = sources; self.aliases = aliases; self.manual = manual
        self.agent = agent; self.lastRefreshAttemptAt = lastRefreshAttemptAt
    }

    public static func initial() -> IndexConfig {
        IndexConfig(sources: IndexSourceRegistry.initial, aliases: AliasTable(), manual: [], agent: .standard,
                    lastRefreshAttemptAt: nil)
    }

    private enum CodingKeys: String, CodingKey { case v, sources, aliases, manual, agent, lastRefreshAttemptAt }

    /// Every key optional: a config written before a key existed must load with that key's
    /// default, not fail and be moved aside with the user's aliases in it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? IndexConfig.currentVersion
        sources = try c.decodeIfPresent([IndexSource].self, forKey: .sources) ?? IndexSourceRegistry.initial
        aliases = try c.decodeIfPresent(AliasTable.self, forKey: .aliases) ?? AliasTable()
        // Element by element: a hand-entered score used to name its agent as free text (the
        // editor's default was "opencode"), and an entry naming an agent this build has no
        // `AgentID` for must cost that one entry, not the whole config — a config that fails to
        // load is moved aside with the user's aliases in it.
        manual = (try c.decodeIfPresent([LossyManualScores].self, forKey: .manual) ?? []).compactMap(\.value)
        agent = try c.decodeIfPresent(IndexAgentSettings.self, forKey: .agent) ?? .standard
        lastRefreshAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastRefreshAttemptAt)
    }

    /// True when the file on disk could not be read AND could not be set aside, so it still holds
    /// the user's only copy of their aliases and hand scores. `save(to:)` refuses while it is set:
    /// the next settings edit (or the weekly refresh's attempt stamp) would otherwise overwrite it.
    /// Not persisted.
    public private(set) var isSaveBlocked = false

    struct SaveBlocked: LocalizedError, Sendable {
        var errorDescription: String? { "the existing settings file could not be read or moved aside, so it was left untouched" }
    }

    /// A missing file is a first launch: the initial config, no problem. A file that exists but
    /// cannot be read, does not decode, or is from a newer Flight Deck is moved aside to
    /// `config.unreadable-<stamp>-<id>.json` before the initial config is returned — the next save
    /// would otherwise overwrite the user's aliases and hand scores in place. If the move fails a
    /// copy is tried; if that fails too the returned config refuses to save (`isSaveBlocked`) and
    /// the problem says the original was left where it is.
    public static func load(from url: URL) -> (config: IndexConfig, problem: String?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (initial(), nil) }
        if let data = try? Data(contentsOf: url),
           let config = try? IndexSnapshot.decoder().decode(IndexConfig.self, from: data), config.v <= currentVersion {
            return (config, nil)
        }
        // The id keeps a second failure in the same second from colliding with the first aside.
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("config.unreadable-\(IndexStamp.string(Date()))-\(UUID().uuidString.prefix(8)).json")
        var fresh = initial()
        if (try? fm.moveItem(at: url, to: aside)) != nil {
            return (fresh, "Capability index settings could not be read. They were moved to \(aside.lastPathComponent) and the defaults loaded.")
        }
        if (try? fm.copyItem(at: url, to: aside)) != nil {
            // The copy keeps the data safe, but the original is still in place: block the save so
            // it is not overwritten either.
            fresh.isSaveBlocked = true
            return (fresh, "Capability index settings could not be read. A copy was saved as \(aside.lastPathComponent), but the original could not be moved, so the defaults are loaded and changes will not be saved.")
        }
        fresh.isSaveBlocked = true
        return (fresh, "Capability index settings could not be read, and could not be moved or copied. The file was left untouched; the defaults are loaded and changes will not be saved.")
    }

    public func save(to url: URL) throws {
        if isSaveBlocked { throw SaveBlocked() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try IndexSnapshot.encoder().encode(self).write(to: url, options: .atomic)
    }
}
