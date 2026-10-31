import Foundation

/// Read access to an intake's `visuals/` folder. ThreadRunner is its only writer (spec §3); the
/// app and the phone's fetch only read, through this, so a test can stand in a fake and the
/// reading code never learns the layout.
public protocol VisualStoreReading {
    /// Every visual that has a `block.json`, sorted by id.
    func visuals() -> [VisualID]
    func blockState(_ id: VisualID) -> BlockState?
    /// The revision numbers on disk, ascending. A folder with no loadable manifest is absent.
    func revisions(_ id: VisualID) -> [Int]
    func revision(_ id: VisualID, r: Int) -> VisualRevision?
    /// A file inside a revision, only if it exists, is a regular file, and stays inside the
    /// revision folder once symlinks are resolved. Nil for anything else: this is the one door
    /// a renderer or `intake.visual.fetch` goes through, so it is where confinement lives.
    func file(_ id: VisualID, r: Int, name: String) -> URL?
}

/// No visuals at all: what a reader gets before the store ships.
public struct EmptyVisualStore: VisualStoreReading, Sendable {
    public init() {}
    public func visuals() -> [VisualID] { [] }
    public func blockState(_ id: VisualID) -> BlockState? { nil }
    public func revisions(_ id: VisualID) -> [Int] { [] }
    public func revision(_ id: VisualID, r: Int) -> VisualRevision? { nil }
    public func file(_ id: VisualID, r: Int, name: String) -> URL? { nil }
}

extension TapeStore {
    /// `<intake>/visuals`: every visual's folder.
    public var visualsRoot: URL { intakeDirectory.appendingPathComponent("visuals", isDirectory: true) }

    /// `<intake>/visuals/<id>`: `block.json` and the revision folders.
    public func visualsDirectory(_ id: VisualID) -> URL {
        visualsRoot.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// `<intake>/visuals/<id>/r<r>`: a revision, which never changes once final.
    public func revisionDirectory(_ id: VisualID, r: Int) -> URL {
        visualsDirectory(id).appendingPathComponent("r\(r)", isDirectory: true)
    }
}
