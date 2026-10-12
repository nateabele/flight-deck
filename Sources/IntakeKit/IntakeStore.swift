import Foundation

/// One directory per intake under `root` (`<stateDir>/intakes`), `intake.json` inside it. The
/// directory — not a single index file — is the unit, because the next plan's runner writes
/// checkpoints and run output beside `intake.json` from another process.
public struct IntakeStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func save(_ intake: Intake) throws {
        let dir = directory(for: intake.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(intake).write(to: dir.appendingPathComponent("intake.json"), options: .atomic)
    }
    public func load(id: UUID) throws -> Intake {
        try IntakeJSON.decoder.decode(Intake.self, from: Data(contentsOf: directory(for: id).appendingPathComponent("intake.json")))
    }
    public func all() -> [Intake] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load(id: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func delete(id: UUID) throws { try FileManager.default.removeItem(at: directory(for: id)) }

    // MARK: - Archive

    /// The empty file whose presence marks an intake archived. A sibling of `intake.json`, never a
    /// field in it: a build from before archiving decodes `intake.json` and writes it back whole
    /// on every state change, so a field it doesn't know would be silently dropped by the first
    /// save it made — the plan would reappear un-archived after a downgrade. A marker file it
    /// never reads survives that, and leaves `intake.json` byte-for-byte what every build expects.
    public static let archivedMarker = "archived"

    public func isArchived(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: id).appendingPathComponent(Self.archivedMarker).path)
    }

    /// Archives or unarchives `id`. Soft: the intake's directory, tape and runs all stay on disk.
    public func setArchived(_ archived: Bool, id: UUID) throws {
        let marker = directory(for: id).appendingPathComponent(Self.archivedMarker)
        if archived {
            try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
            try Data().write(to: marker, options: .atomic)
        } else if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }
}
