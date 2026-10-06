import Foundation

public enum AliasStatus: String, Codable, Sendable { case confirmed, pending, rejected }

/// `(source, benchmarkModel)` → a model Flight Deck can run, with the knobs that benchmark ran
/// it at ("GPT-6 Sol (high)" → codex gpt-6-sol, effort high).
public struct AliasEntry: Codable, Equatable, Sendable {
    public var source: String
    public var benchmarkModel: String
    public var model: ModelRef
    public var status: AliasStatus
    public init(source: String, benchmarkModel: String, model: ModelRef, status: AliasStatus) {
        self.source = source; self.benchmarkModel = benchmarkModel; self.model = model; self.status = status
    }
}

/// A benchmark name no confirmed alias covers. Kept on the snapshot so Settings can offer to map it.
public struct UnmappedName: Codable, Hashable, Comparable, Sendable {
    public var source: String
    public var benchmarkModel: String
    public init(source: String, benchmarkModel: String) { self.source = source; self.benchmarkModel = benchmarkModel }
    public static func < (a: UnmappedName, b: UnmappedName) -> Bool {
        (a.source, a.benchmarkModel) < (b.source, b.benchmarkModel)
    }
}

/// The alias table. Matching is exact on the source and on the trimmed name — never fuzzy: a
/// guessed mapping would silently credit one model with another's score, and nothing downstream
/// could tell. Proposals exist to make confirming cheap, not to skip it.
public struct AliasTable: Codable, Equatable, Sendable {
    public var entries: [AliasEntry]
    public init(entries: [AliasEntry] = []) { self.entries = entries }

    private static func same(_ e: AliasEntry, _ source: String, _ name: String) -> Bool {
        e.source == source
            && e.benchmarkModel.trimmingCharacters(in: .whitespaces) == name.trimmingCharacters(in: .whitespaces)
    }

    /// The model a name maps to — confirmed entries only.
    public func model(source: String, benchmarkModel: String) -> ModelRef? {
        entries.first { $0.status == .confirmed && Self.same($0, source, benchmarkModel) }?.model
    }

    public func entry(source: String, benchmarkModel: String) -> AliasEntry? {
        entries.first { Self.same($0, source, benchmarkModel) }
    }

    public var confirmed: [AliasEntry] { entries.filter { $0.status == .confirmed } }
    public var pending: [AliasEntry] { entries.filter { $0.status == .pending } }

    /// Adds proposals for names the table has never seen, as pending. A name the user rejected
    /// keeps its `.rejected` entry, which is what stops the next refresh proposing it again.
    public mutating func addProposals(_ proposals: [AliasEntry]) {
        for p in proposals where entry(source: p.source, benchmarkModel: p.benchmarkModel) == nil {
            var e = p
            e.status = .pending
            entries.append(e)
        }
    }

    public mutating func set(source: String, benchmarkModel: String, model: ModelRef, status: AliasStatus) {
        entries.removeAll { Self.same($0, source, benchmarkModel) }
        entries.append(AliasEntry(source: source, benchmarkModel: benchmarkModel, model: model, status: status))
    }

    @discardableResult
    public mutating func confirm(source: String, benchmarkModel: String) -> Bool {
        guard let i = entries.firstIndex(where: { Self.same($0, source, benchmarkModel) }) else { return false }
        entries[i].status = .confirmed
        return true
    }

    @discardableResult
    public mutating func reject(source: String, benchmarkModel: String) -> Bool {
        guard let i = entries.firstIndex(where: { Self.same($0, source, benchmarkModel) }) else { return false }
        entries[i].status = .rejected
        return true
    }

    public mutating func remove(source: String, benchmarkModel: String) {
        entries.removeAll { Self.same($0, source, benchmarkModel) }
    }
}

/// A `ModelRef` as one stable string (`codex/gpt-6-sol[effort=high]`) and as words for the UI.
/// Knobs are sorted, so two refs that differ only in dictionary order are one key.
public enum IndexKeys {
    public static func key(_ ref: ModelRef) -> String {
        let knobs = ref.knobs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let base = "\(ref.harness.rawValue)/\(ref.model)"
        return knobs.isEmpty ? base : "\(base)[\(knobs)]"
    }

    public static func label(_ ref: ModelRef) -> String {
        let knobs = ref.knobs.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let base = "\(ref.harness.rawValue) · \(ref.model)"
        return knobs.isEmpty ? base : "\(base) (\(knobs))"
    }
}

/// Proposes aliases for names a refresh could not map. A proposal is only ever an EXACT match
/// after normalization (`KindID.normalized`) against a catalog model's id or display name; a
/// bracketed setting becomes a knob only when the catalog's knob schema allows that value. Every
/// proposal is pending until the user confirms it in Settings.
public enum AliasProposer {
    public static func propose(_ names: [UnmappedName], table: AliasTable, catalogs: AdapterCatalogs) -> [AliasEntry] {
        var out: [AliasEntry] = []
        for name in names.sorted() {
            guard table.entry(source: name.source, benchmarkModel: name.benchmarkModel) == nil,
                  !out.contains(where: { $0.source == name.source && $0.benchmarkModel == name.benchmarkModel }),
                  let ref = match(name.benchmarkModel, catalogs: catalogs) else { continue }
            out.append(AliasEntry(source: name.source, benchmarkModel: name.benchmarkModel, model: ref, status: .pending))
        }
        return out
    }

    /// "GPT-6 Sol (High)" → ("gpt-6-sol", "high").
    public static func split(_ name: String) -> (base: String, setting: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return (KindID.normalized(trimmed).rawValue, nil)
        }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces).lowercased()
        return (KindID.normalized(String(trimmed[..<open])).rawValue, inner.isEmpty ? nil : inner)
    }

    static func match(_ name: String, catalogs: AdapterCatalogs) -> ModelRef? {
        let (base, setting) = split(name)
        guard !base.isEmpty else { return nil }
        for harness in catalogs.order {
            guard let cat = catalogs.byHarness[harness] else { continue }
            for entry in cat.models where KindID.normalized(entry.id).rawValue == base
                || KindID.normalized(entry.displayName).rawValue == base {
                var knobs: [String: String] = [:]
                if let setting, let knob = entry.knobs.sorted().first(where: { cat.knobSchema[$0]?.contains(setting) == true }) {
                    knobs[knob] = setting
                }
                return ModelRef(harness: harness, model: entry.id, knobs: knobs)
            }
        }
        return nil
    }
}
