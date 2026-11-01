import XCTest
import IntakeKit

/// `DiskVisualStore` (R-I6): V1's renderer and V3's fetch both read through it, so it is where
/// "serves only files the manifest lists, never a symlink, never outside the revision" lives.
final class DiskVisualStoreTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private let id = VisualID(rawValue: "flow")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskVisual-\(UUID())", isDirectory: true)
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("DiskVisualOut-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    private var tape: TapeStore { TapeStore(intakeDirectory: root) }
    private var store: DiskVisualStore { DiskVisualStore(intakeDirectory: root) }
    private var rev: URL { tape.revisionDirectory(id, r: 1) }

    private func read(_ name: String, r: Int = 1, offset: Int64 = 0, limit: Int = 1 << 20) -> VisualFileSlice? {
        store.read(id, r: r, name: name, offset: offset, limit: limit)
    }

    private func manifest(files: [String], sizes: [String: Int64] = [:]) -> VisualManifest {
        VisualManifest(provider: "mermaid", providerVersion: "1", kind: "diagram", title: "T", entry: "diagram.mmd",
                       madeOnCheckpoint: 1, madeBy: .you, primary: true,
                       files: files.map { VisualFileEntry(path: $0, size: sizes[$0] ?? 0, sha256: "") })
    }

    /// Writes a revision's file and, unless the test pinned that entry's size, records the file's
    /// true size in the manifest, as a writer does.
    private func write(_ name: String, _ text: String = "x", in dir: URL? = nil) throws {
        let folder = dir ?? rev
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard !pinned.contains(name), let data = try? Data(contentsOf: manifestURL),
              var m = try? IntakeJSON.decoder.decode(VisualManifest.self, from: data) else { return }
        m.files = m.files.map { $0.path == name ? VisualFileEntry(path: name, size: Int64(text.utf8.count), sha256: $0.sha256) : $0 }
        try IntakeJSON.encoder.encode(m).write(to: manifestURL)
    }
    private var pinned: Set<String> = []

    private func install(files: [String], r: Int = 1, sizes: [String: Int64] = [:]) throws {
        pinned.formUnion(sizes.keys)
        let dir = tape.revisionDirectory(id, r: r)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(manifest(files: files, sizes: sizes)).write(to: dir.appendingPathComponent("manifest.json"))
    }

    // MARK: - Reading

    func testAnEmptyIntakeHasNoVisuals() {
        XCTAssertTrue(store.visuals().isEmpty)
        XCTAssertNil(store.blockState(id))
        XCTAssertTrue(store.revisions(id).isEmpty)
        XCTAssertNil(store.revision(id, r: 1))
    }

    func testItReadsBlockStateRevisionsAndManifests() throws {
        try install(files: ["diagram.mmd"], r: 1)
        try install(files: ["diagram.mmd"], r: 2)
        try install(files: [], r: 10)
        let other = VisualID(rawValue: "other")!
        try FileManager.default.createDirectory(at: tape.visualsDirectory(other), withIntermediateDirectories: true)
        let state = BlockState(representations: [RevisionRef(visualID: id, r: 1), RevisionRef(visualID: id, r: 2)],
                               primary: RevisionRef(visualID: id, r: 2))
        try IntakeJSON.encoder.encode(state).write(to: tape.visualsDirectory(id).appendingPathComponent("block.json"))
        // A folder that is not `r<n>`, and one whose manifest does not load, are not revisions.
        try FileManager.default.createDirectory(at: tape.visualsDirectory(id).appendingPathComponent("scratch"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tape.revisionDirectory(id, r: 3), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: tape.revisionDirectory(id, r: 3).appendingPathComponent("manifest.json"))

        XCTAssertEqual(store.visuals(), [id], "only a visual with a block.json is listed")
        XCTAssertEqual(store.blockState(id), state)
        XCTAssertEqual(store.revisions(id), [1, 2, 10], "numeric, ascending")
        XCTAssertEqual(store.revision(id, r: 2)?.manifest, manifest(files: ["diagram.mmd"]))
        XCTAssertEqual(store.revision(id, r: 2)?.ref, RevisionRef(visualID: id, r: 2))
        XCTAssertNil(store.revision(id, r: 3))
    }

    func testBlockStatesPerCheckpoint() throws {
        let ref = RevisionRef(visualID: id, r: 1)
        let state = BlockState(representations: [ref], primary: ref)
        let dir = tape.checkpointDirectory(4)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(CheckpointBlockStates(states: [id: state])).write(to: tape.checkpointVisualsURL(4))
        XCTAssertEqual(store.blockState(id, checkpoint: 4), state)
        XCTAssertNil(store.blockState(id, checkpoint: 5), "no file: the plan had no visual state then")
        XCTAssertNil(store.blockState(VisualID(rawValue: "other")!, checkpoint: 4))
    }

    // MARK: - Confinement

    func testAListedRegularFileIsRead() throws {
        try install(files: ["diagram.mmd", "export/index.html"])
        try write("diagram.mmd"); try write("export/index.html")
        XCTAssertEqual(read("diagram.mmd"), VisualFileSlice(data: Data("x".utf8), size: 1))
        XCTAssertEqual(read("export/index.html")?.data, Data("x".utf8))
    }

    func testAFileTheManifestDoesNotListIsNeverServed() throws {
        try install(files: ["diagram.mmd"])
        try write("diagram.mmd"); try write("secret.txt"); try write("pins.json")
        XCTAssertNil(read("secret.txt"))
        XCTAssertNil(read("manifest.json"))
        XCTAssertNil(read("pins.json"))
    }

    func testAListedFileThatIsMissingIsNil() throws {
        try install(files: ["diagram.mmd"])
        XCTAssertNil(read("diagram.mmd"))
    }

    func testDotDotAndAbsolutePathsAreRefusedEvenWhenListed() throws {
        let sneaky = ["../r2/x", "export/../diagram.mmd", "/etc/hosts", "./diagram.mmd", "a//b", "", "export/", "..", "a\0b"]
        try install(files: sneaky + ["diagram.mmd"])
        try write("diagram.mmd")
        try write("x", in: tape.revisionDirectory(id, r: 2))
        for name in sneaky { XCTAssertNil(read(name), name) }
    }

    func testASymlinkPointingOutIsRefusedEvenWhenListed() throws {
        try install(files: ["leak.txt"])
        try Data("secret".utf8).write(to: outside.appendingPathComponent("target.txt"))
        try FileManager.default.createSymbolicLink(at: rev.appendingPathComponent("leak.txt"),
                                                   withDestinationURL: outside.appendingPathComponent("target.txt"))
        XCTAssertNil(read("leak.txt"))
    }

    func testASymlinkInsideTheRevisionIsRefusedToo() throws {
        try install(files: ["alias.txt"])
        try write("real.txt")
        try FileManager.default.createSymbolicLink(at: rev.appendingPathComponent("alias.txt"),
                                                   withDestinationURL: rev.appendingPathComponent("real.txt"))
        XCTAssertNil(read("alias.txt"))
    }

    func testAListedFileUnderASymlinkedDirectoryIsRefused() throws {
        try install(files: ["export/index.html"])
        try Data("secret".utf8).write(to: outside.appendingPathComponent("index.html"))
        try FileManager.default.createSymbolicLink(at: rev.appendingPathComponent("export"), withDestinationURL: outside)
        XCTAssertNil(read("export/index.html"))
    }

    func testAFifoIsRefusedAndDoesNotBlock() throws {
        try install(files: ["pipe"])
        XCTAssertEqual(mkfifo(rev.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertNil(read("pipe"))
    }

    func testADirectoryNamedInTheManifestIsRefused() throws {
        try install(files: ["export"])
        try FileManager.default.createDirectory(at: rev.appendingPathComponent("export"), withIntermediateDirectories: true)
        XCTAssertNil(read("export"))
    }

    func testASymlinkedRevisionFolderIsRefused() throws {
        try install(files: ["a.txt"], r: 1)
        try write("a.txt")
        let linked = tape.revisionDirectory(id, r: 2)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: rev)
        XCTAssertNil(read("a.txt", r: 2))
        XCTAssertNil(store.revision(id, r: 2))
    }

    // MARK: - Bytes, not paths

    func testASliceCarriesTheFilesSizeFromTheSameDescriptor() throws {
        try install(files: ["a.bin"])
        try write("a.bin", "0123456789")
        XCTAssertEqual(read("a.bin", offset: 0, limit: 4), VisualFileSlice(data: Data("0123".utf8), size: 10))
        XCTAssertEqual(read("a.bin", offset: 4, limit: 4), VisualFileSlice(data: Data("4567".utf8), size: 10))
        XCTAssertEqual(read("a.bin", offset: 8, limit: 100), VisualFileSlice(data: Data("89".utf8), size: 10), "short at the end")
    }

    func testAnOffsetAtOrPastTheEndIsAnEmptySliceNotARefusalOfTheFile() throws {
        try install(files: ["a.bin"])
        try write("a.bin", "0123456789")
        XCTAssertEqual(read("a.bin", offset: 10, limit: 4), VisualFileSlice(data: Data(), size: 10), "the end: the phone learns it is done")
        XCTAssertNil(read("a.bin", offset: 11, limit: 4), "past the end is a bad request")
        XCTAssertNil(read("a.bin", offset: Int64.max, limit: 4))
    }

    func testANegativeOffsetOrLimitIsRefused() throws {
        try install(files: ["a.bin"])
        try write("a.bin", "0123456789")
        XCTAssertNil(read("a.bin", offset: -1, limit: 4))
        XCTAssertNil(read("a.bin", offset: 0, limit: -1))
        XCTAssertEqual(read("a.bin", offset: 0, limit: 0)?.data, Data(), "a zero limit is a size probe")
    }

    func testAHardLinkIsRefused() throws {
        try install(files: ["a.txt", "linked.txt"])
        try write("a.txt")
        try FileManager.default.linkItem(at: rev.appendingPathComponent("a.txt"), to: rev.appendingPathComponent("linked.txt"))
        XCTAssertNil(read("linked.txt"))
        XCTAssertNil(read("a.txt"), "both names of a shared inode are refused")
    }

    func testASizeThatDisagreesWithTheManifestIsRefused() throws {
        try install(files: ["a.txt", "b.txt", "c.txt"], sizes: ["a.txt": 5, "b.txt": 99, "c.txt": 0])
        try write("a.txt", "12345"); try write("b.txt", "12345"); try write("c.txt", "12345")
        XCTAssertNotNil(read("a.txt"), "matches")
        XCTAssertNil(read("b.txt"), "differs")
        XCTAssertNil(read("c.txt"), "a listed size of 0 is refused, not taken as unrecorded")
    }

    func testAFileOverTheLimitIsRefused() throws {
        try install(files: ["big.bin"])
        let m = VisualManifest(provider: "mermaid", providerVersion: "1", kind: "diagram", title: "T", entry: "big.bin",
                               madeOnCheckpoint: 1, madeBy: .you, primary: true,
                               files: [VisualFileEntry(path: "big.bin", size: Int64(VisualStoreLimits.maxFileBytes), sha256: "")])
        try IntakeJSON.encoder.encode(m).write(to: rev.appendingPathComponent("manifest.json"))
        let fd = open(rev.appendingPathComponent("big.bin").path, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(VisualStoreLimits.maxFileBytes + 1)), 0)   // sparse: no real disk
        close(fd)
        XCTAssertNil(read("big.bin"))
        XCTAssertEqual(ftruncate(open(rev.appendingPathComponent("big.bin").path, O_WRONLY), off_t(VisualStoreLimits.maxFileBytes)), 0)
        XCTAssertEqual(read("big.bin", limit: 1)?.size, Int64(VisualStoreLimits.maxFileBytes), "exactly the limit is allowed")
    }

    func testAMissingVisualsFolderIsToleratedAndServesNothingUntilItAppears() throws {
        XCTAssertNil(read("a.txt"))
        XCTAssertTrue(store.visuals().isEmpty)
        try install(files: ["a.txt"])
        try write("a.txt")
        XCTAssertNotNil(read("a.txt"), "the same store value sees the folder once it exists")
    }
}
