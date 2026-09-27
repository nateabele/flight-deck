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
}
