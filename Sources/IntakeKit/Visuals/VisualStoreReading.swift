import Foundation

/// Read access to an intake's `visuals/` folder. ThreadRunner is its only writer (spec §3); the
/// app and the phone's fetch only read, through this, so a test can stand in a fake and the
/// reading code never learns the layout.
public protocol VisualStoreReading: Sendable {
    /// Every visual that has a `block.json`, sorted by id.
    func visuals() -> [VisualID]
    func blockState(_ id: VisualID) -> BlockState?
    /// The block state checkpoint `checkpoint` recorded (`checkpoints/<n>/visuals.json`); nil if
    /// that checkpoint recorded none, such as one made before visuals.
    func blockState(_ id: VisualID, checkpoint: Int) -> BlockState?
    /// The revision numbers on disk, ascending. A folder with no loadable manifest is absent.
    func revisions(_ id: VisualID) -> [Int]
    func revision(_ id: VisualID, r: Int) -> VisualRevision?
    /// A file inside a revision, only if it exists, is a regular file, and stays inside the
    /// revision folder once symlinks are resolved. Nil for anything else: this is the one door
    /// a renderer or `intake.visual.fetch` goes through, so it is where confinement lives.
    /// Only a file the revision's manifest lists (`VisualManifest.files`), by its relative path.
    func file(_ id: VisualID, r: Int, name: String) -> URL?
}

/// No visuals at all: what a reader gets before the store ships.
public struct EmptyVisualStore: VisualStoreReading, Sendable {
    public init() {}
    public func visuals() -> [VisualID] { [] }
    public func blockState(_ id: VisualID) -> BlockState? { nil }
    public func blockState(_ id: VisualID, checkpoint: Int) -> BlockState? { nil }
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

    /// `<intake>/checkpoints/<n>/visuals.json`: the block states checkpoint `n` recorded.
    public func checkpointVisualsURL(_ checkpoint: Int) -> URL {
        checkpointDirectory(checkpoint).appendingPathComponent("visuals.json")
    }

    /// `<intake>/visuals/<id>/r<r>/export`: a comp's exported files, which the phone fetches and
    /// the release export copies.
    public func exportDirectory(_ id: VisualID, r: Int) -> URL {
        revisionDirectory(id, r: r).appendingPathComponent("export", isDirectory: true)
    }

    /// `<intake>/visuals/<id>/r<r>`: a revision, which never changes once final.
    public func revisionDirectory(_ id: VisualID, r: Int) -> URL {
        visualsDirectory(id).appendingPathComponent("r\(r)", isDirectory: true)
    }
}
