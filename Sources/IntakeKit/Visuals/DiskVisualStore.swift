import Foundation

/// Reads an intake's `visuals/` folder from disk. V1's renderer and V3's phone fetch both read
/// through this, so confinement lives here once.
///
/// **`file(_:r:name:)` serves only what the manifest lists, and only a plain file inside the
/// revision.** Every refusal below returns nil, never throws, so a caller has one thing to check:
/// - a name the manifest's `files` does not list (so `manifest.json`, `pins.json` and anything a
///   stray process dropped in the folder are never served);
/// - a name that is empty, absolute, has a `.` or `..` or empty component, or contains a NUL;
/// - any symlink on the way, the revision folder and the file itself included (each step is
///   `openat(O_NOFOLLOW)`, so a link swapped in after the check still fails);
/// - anything that is not a regular file, by `fstat` on the opened descriptor. A FIFO would
///   otherwise block a reader forever; it is opened `O_NONBLOCK` so the check itself cannot.
///
/// The returned URL names the path, not the descriptor, so a file replaced between this call and
/// the caller's read is not caught. Revisions never change once final (§7), and the only writer
/// is ThreadRunner, so that window is not an attack surface this store closes.
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

    public func file(_ id: VisualID, r: Int, name: String) -> URL? {
        guard r >= 0, let revision = revision(id, r: r),
              revision.manifest.files.contains(where: { $0.path == name }),
              let parts = Self.components(of: name) else { return nil }
        let path = ["visuals", id.rawValue, "r\(r)"] + parts
        guard let fd = openConfined(path, regularFile: true) else { return nil }
        close(fd)
        return path.reduce(intakeDirectory) { $0.appendingPathComponent($1) }
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
    /// may be a symlink. The last one must be a regular file when `regularFile`, and a directory
    /// otherwise. The caller closes the descriptor.
    private func openConfined(_ parts: [String], regularFile: Bool) -> Int32? {
        var dir = open(intakeDirectory.path, O_RDONLY | O_DIRECTORY)
        guard dir >= 0 else { return nil }
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | ((last && regularFile) ? 0 : O_DIRECTORY)
            let next = openat(dir, part, flags)
            close(dir)
            guard next >= 0 else { return nil }
            dir = next
        }
        var st = stat()
        guard fstat(dir, &st) == 0, (regularFile ? (st.st_mode & S_IFMT) == S_IFREG : (st.st_mode & S_IFMT) == S_IFDIR) else {
            close(dir)
            return nil
        }
        return dir
    }

    private func read<T: Decodable>(_ type: T.Type, _ parts: [String]) -> T? {
        guard let fd = openConfined(parts, regularFile: true) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: Self.maxJSON + 1), data.count <= Self.maxJSON else { return nil }
        return try? IntakeJSON.decoder.decode(type, from: data)
    }
}
