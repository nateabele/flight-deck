import Foundation

/// Bytes read from one file of a revision, with the file's size as that same read saw it.
public struct VisualFileSlice: Equatable, Sendable {
    public var data: Data
    /// The whole file's size, from the `fstat` of the descriptor `data` was read from.
    public var size: Int64
    public init(data: Data, size: Int64) { self.data = data; self.size = size }
}

public enum VisualStoreLimits {
    /// The most one file may be and still be read. IntakeKit's copy of FleetKit's
    /// `VisualLimits.maxBytes` (a hosted test pins the two together).
    public static let maxFileBytes = 10_485_760
}

/// Read access to an intake's `visuals/` folder. ThreadRunner is the only writer of `visuals/`
/// (spec §3); the app and the phone's fetch only read, through this, so a test can stand in a fake
/// and the reading code never learns the layout.
///
/// **The store hands out bytes, never paths.** A path can be reopened later, after the file under
/// it has changed; a slice cannot. `read` is the one door a renderer or `intake.visual.fetch`
/// goes through, so confinement lives behind it.
public protocol VisualStoreReading: Sendable {
    /// Every visual that has a `block.json`, sorted by id.
    func visuals() -> [VisualID]
    /// The visual's current block state (`visuals/<id>/block.json`).
    func blockState(_ id: VisualID) -> BlockState?
    /// The block state checkpoint `checkpoint` recorded (`checkpoints/<n>/visuals.json`); nil if
    /// that checkpoint recorded none, such as one made before visuals.
    func blockState(_ id: VisualID, checkpoint: Int) -> BlockState?
    /// The revision numbers on disk, ascending. A folder with no loadable manifest is absent.
    func revisions(_ id: VisualID) -> [Int]
    func revision(_ id: VisualID, r: Int) -> VisualRevision?
    /// Up to `limit` bytes of a revision's file from `offset`, only if the revision's manifest
    /// lists `name` (`VisualManifest.files`) and the file is a plain file inside the revision
    /// folder. A symlink anywhere on the way is refused, not followed. Nil for anything else, and
    /// for a negative `offset` or `limit` or an `offset` past the end. An `offset` at the end is
    /// an empty slice, so a reader learns it is done.
    func read(_ id: VisualID, r: Int, name: String, offset: Int64, limit: Int) -> VisualFileSlice?
}

/// No visuals at all: what a reader gets before the store ships.
public struct EmptyVisualStore: VisualStoreReading, Sendable {
    public init() {}
    public func visuals() -> [VisualID] { [] }
    public func blockState(_ id: VisualID) -> BlockState? { nil }
    public func blockState(_ id: VisualID, checkpoint: Int) -> BlockState? { nil }
    public func revisions(_ id: VisualID) -> [Int] { [] }
    public func revision(_ id: VisualID, r: Int) -> VisualRevision? { nil }
    public func read(_ id: VisualID, r: Int, name: String, offset: Int64, limit: Int) -> VisualFileSlice? { nil }
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
