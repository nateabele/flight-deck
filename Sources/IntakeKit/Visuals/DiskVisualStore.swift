import Foundation

/// Reads an intake's `visuals/` folder from disk. V1's renderer and V3's phone fetch both read
/// through this, so confinement lives here once. A missing `visuals/` folder is fine: the store
/// serves nothing until the folder exists, so it can be handed out before any visual does.
///
/// **`read(_:r:name:offset:limit:)` serves only what the manifest lists, and only a plain file
/// inside the revision.** Every refusal returns nil, never throws, so a caller has one thing to
/// check:
/// - a name the manifest's `files` does not list (so `manifest.json`, `pins.json` and anything a
///   stray process dropped in the folder are never served);
/// - a name that is empty, absolute, has a `.` or `..` or empty component, or contains a NUL;
/// - any symlink on the way, the revision folder and the file itself included. They are refused,
///   not resolved: each step is `openat(O_NOFOLLOW)`, so a link swapped in after a check still fails;
/// - anything that is not a regular file, by `fstat` on the opened descriptor. A FIFO would
///   otherwise block a reader forever; it is opened `O_NONBLOCK` so the check itself cannot;
/// - a file with another hard link (`st_nlink > 1`), which could be the same inode as a file
///   outside the folder;
/// - a file over `VisualStoreLimits.maxFileBytes`, or whose size differs from the manifest
///   entry's. An entry whose size is 0 or less is refused: an empty file is not a visual, and an
///   unrecorded size would let the export read a file of any length.
///
/// The bytes come from `pread` on that same checked descriptor and the size from its `fstat`, so
/// nothing is reopened by path afterwards. The store hands out no URLs.
public struct DiskVisualStore: VisualStoreReading, Sendable {
    public let intakeDirectory: URL
    public init(intakeDirectory: URL) { self.intakeDirectory = intakeDirectory }
    public init(tape: TapeStore) { self.intakeDirectory = tape.intakeDirectory }

    private var tape: TapeStore { TapeStore(intakeDirectory: intakeDirectory) }
    /// The most JSON this store reads: a manifest or block state is a few KB, and a runaway file
    /// must not be pulled into memory.
    private static let maxJSON = 1_048_576

    public func visuals() -> [VisualID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tape.visualsRoot.path)) ?? []
        return names.compactMap(VisualID.init(rawValue:)).filter { blockState($0) != nil }.sorted()
    }

    public func blockState(_ id: VisualID) -> BlockState? {
        read(BlockState.self, ["visuals", id.rawValue, "block.json"])
    }

    public func blockState(_ id: VisualID, checkpoint: Int) -> BlockState? {
        read(CheckpointBlockStates.self, ["checkpoints", String(checkpoint), "visuals.json"])?.states[id]
    }

    public func revisions(_ id: VisualID) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tape.visualsDirectory(id).path)) ?? []
        return names.compactMap(Self.revisionNumber).filter { revision(id, r: $0) != nil }.sorted()
    }

    public func revision(_ id: VisualID, r: Int) -> VisualRevision? {
        guard r >= 0, let manifest = read(VisualManifest.self, ["visuals", id.rawValue, "r\(r)", "manifest.json"]) else { return nil }
        return VisualRevision(id: id, r: r, manifest: manifest)
    }

    public func read(_ id: VisualID, r: Int, name: String, offset: Int64, limit: Int) -> VisualFileSlice? {
        guard r >= 0, offset >= 0, limit >= 0, let revision = revision(id, r: r),
              let entry = revision.manifest.files.first(where: { $0.path == name }),
              let parts = Self.components(of: name),
              let fd = openConfined(["visuals", id.rawValue, "r\(r)"] + parts) else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
              st.st_size <= off_t(VisualStoreLimits.maxFileBytes),
              entry.size > 0, entry.size == Int64(st.st_size) else { return nil }
        let size = Int64(st.st_size)
        guard offset <= size else { return nil }
        let want = Int(min(Int64(limit), size - offset))
        var data = Data(count: want)
        var got = 0
        while got < want {
            let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, want - got, off_t(offset) + off_t(got)) }
            if n < 0 { return nil }
            if n == 0 { break }
            got += n
        }
        return VisualFileSlice(data: Data(data.prefix(got)), size: size)
    }

    // MARK: - Confined opening

    /// `r<n>` with a plain decimal `n`: not `r01`, `r-1` or `r1x`, which would be a second name
    /// for a revision or no revision at all.
    private static func revisionNumber(_ folder: String) -> Int? {
        guard folder.first == "r", let n = Int(folder.dropFirst()), n >= 0, "r\(n)" == folder else { return nil }
        return n
    }

    /// The `/`-separated parts of a manifest path, or nil if any part could leave the folder.
    private static func components(of name: String) -> [String]? {
        guard !name.isEmpty, !name.contains("\0") else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts
    }

    /// Opens `intakeDirectory/<parts>` one component at a time with `O_NOFOLLOW`, so no component
    /// may be a symlink; every component but the last must be a directory. The caller `fstat`s the
    /// last one (regular file, links, size) and closes the descriptor.
    private func openConfined(_ parts: [String]) -> Int32? {
        var dir = open(intakeDirectory.path, O_RDONLY | O_DIRECTORY)
        guard dir >= 0 else { return nil }
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (last ? 0 : O_DIRECTORY)
            let next = openat(dir, part, flags)
            close(dir)
            guard next >= 0 else { return nil }
            dir = next
        }
        return dir
    }

    private func read<T: Decodable>(_ type: T.Type, _ parts: [String]) -> T? {
        guard let fd = openConfined(parts) else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: Self.maxJSON + 1), data.count <= Self.maxJSON else { return nil }
        return try? IntakeJSON.decoder.decode(type, from: data)
    }
}
