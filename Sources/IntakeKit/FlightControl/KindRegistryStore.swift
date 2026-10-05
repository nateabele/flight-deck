import Foundation

public enum KindRegistryError: Error, Equatable, Sendable {
    case unreadable(String)
    case newerVersion(Int)
    case unknownKind(KindID)
    case invalid(KindValidationError)
    case mergeIntoSelf(KindID)
    case mergeIntoMerged(KindID)

    /// Shown in Settings → Task kinds.
    public var message: String {
        switch self {
        case .unreadable(let why): return "kinds.json could not be read: \(why)"
        case .newerVersion(let v): return "kinds.json was written by a newer Flight Deck (v\(v))"
        case .unknownKind(let id): return "unknown task kind \(id.rawValue)"
        case .invalid(let e):
            switch e {
            case .emptyName: return "a kind needs a name"
            case .unknownDimension(let d): return "unknown dimension \(d)"
            case .weightOutOfRange(let d, let w): return "\(d) weight \(RuleText.number(w)) is outside 0–1"
            }
        case .mergeIntoSelf(let id): return "\(id.rawValue) cannot be merged into itself"
        case .mergeIntoMerged(let id): return "\(id.rawValue) has itself been merged; merge into the kind it points to"
        }
    }
}

/// The project's kind registry, `.flightdeck/kinds.json` (L3-0 §6) — the real `KindRegistry`.
///
/// In the repo on purpose: it is versioned with the project, and planning agents read it. A
/// project with no file sees the seed set and nothing is written until something changes, so
/// opening Settings on a repo never dirties its working tree.
///
/// The lock serializes read-modify-write within this process. The only other writer is a
/// person editing the file; a file this store cannot read is reported and never overwritten.
public final class KindRegistryStore: KindRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public static func fileURL(project: URL) -> URL {
        project.appendingPathComponent(".flightdeck", isDirectory: true).appendingPathComponent("kinds.json")
    }

    /// The kinds a planning prompt offers. Empty when the file is unreadable: a broken registry
    /// must not stop a round, and its tasks then route by the fallback kind.
    public static func promptKinds(project: URL) -> [TaskKind] {
        (try? KindRegistryStore().kinds(project: project)) ?? []
    }

    public func kinds(project: URL) throws -> [TaskKind] {
        try lock.withLock { try read(project).kinds }
    }

    /// Adds `kind` under the id its name normalizes to, or returns the kind that id already
    /// names. Reusing by normalized name is what stops "Snapshot Tests" and "snapshot tests"
    /// from becoming two kinds that each route on their own.
    public func propose(_ kind: TaskKind, project: URL) throws -> TaskKind {
        try lock.withLock {
            var file = try read(project)
            let id = KindID.normalized(kind.name)
            guard !id.rawValue.isEmpty else { throw KindRegistryError.invalid(.emptyName) }
            if let existing = file.kinds.first(where: { $0.id == id }) { return existing }
            var added = kind
            added.id = id
            try Self.validate(added)
            file.kinds.append(added)
            try write(file, project)
            return added
        }
    }

    public func rename(_ id: KindID, to name: String, project: URL) throws {
        try mutate(project) { file in
            guard let i = file.kinds.firstIndex(where: { $0.id == id }) else { throw KindRegistryError.unknownKind(id) }
            var k = file.kinds[i]
            k.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validate(k)
            file.kinds[i] = k
        }
    }

    public func reweight(_ id: KindID, dimensions: [String: Double], project: URL) throws {
        try mutate(project) { file in
            guard let i = file.kinds.firstIndex(where: { $0.id == id }) else { throw KindRegistryError.unknownKind(id) }
            var k = file.kinds[i]
            k.dimensions = dimensions
            try Self.validate(k)
            file.kinds[i] = k
        }
    }

    /// Marks `id` as `merged:<target>`. No task is rewritten: blocks keep naming `id`, and
    /// resolution follows the link. The target must be live — merging into a kind that was
    /// itself merged would build a chain someone has to read twice to follow.
    public func merge(_ id: KindID, into target: KindID, project: URL) throws {
        try mutate(project) { file in
            guard id != target else { throw KindRegistryError.mergeIntoSelf(id) }
            guard let i = file.kinds.firstIndex(where: { $0.id == id }) else { throw KindRegistryError.unknownKind(id) }
            guard let t = file.kinds.first(where: { $0.id == target }) else { throw KindRegistryError.unknownKind(target) }
            if case .merged = t.status { throw KindRegistryError.mergeIntoMerged(target) }
            file.kinds[i].status = .merged(into: target)
        }
    }

    // MARK: - File

    private static func validate(_ kind: TaskKind) throws {
        do { try kind.validate() } catch let e as KindValidationError { throw KindRegistryError.invalid(e) }
    }

    private func mutate(_ project: URL, _ body: (inout KindRegistryFile) throws -> Void) throws {
        try lock.withLock {
            var file = try read(project)
            try body(&file)
            try write(file, project)
        }
    }

    private func read(_ project: URL) throws -> KindRegistryFile {
        let url = Self.fileURL(project: project)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return KindRegistryFile(kinds: SeedKinds.all(createdAt: now()))
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw KindRegistryError.unreadable("\(error)") }
        struct Version: Decodable { let v: Int? }
        if let v = (try? JSONDecoder().decode(Version.self, from: data))?.v, v > 1 {
            throw KindRegistryError.newerVersion(v)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(KindRegistryFile.self, from: data) }
        catch { throw KindRegistryError.unreadable("\(error)") }
    }

    private func write(_ file: KindRegistryFile, _ project: URL) throws {
        let url = Self.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}
