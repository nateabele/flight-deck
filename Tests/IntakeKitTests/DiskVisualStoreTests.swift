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

    private func manifest(files: [String]) -> VisualManifest {
        VisualManifest(provider: "mermaid", providerVersion: "1", kind: "diagram", title: "T", entry: "diagram.mmd",
                       madeOnCheckpoint: 1, madeBy: .you, primary: true,
                       files: files.map { VisualFileEntry(path: $0, size: 0, sha256: "") })
    }

    private func write(_ name: String, _ text: String = "x", in dir: URL? = nil) throws {
        let url = (dir ?? rev).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func install(files: [String], r: Int = 1) throws {
        let dir = tape.revisionDirectory(id, r: r)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(manifest(files: files)).write(to: dir.appendingPathComponent("manifest.json"))
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

    func testAListedRegularFileIsServed() throws {
        try install(files: ["diagram.mmd", "export/index.html"])
        try write("diagram.mmd"); try write("export/index.html")
        XCTAssertEqual(store.file(id, r: 1, name: "diagram.mmd")?.lastPathComponent, "diagram.mmd")
        XCTAssertEqual(store.file(id, r: 1, name: "export/index.html")?.lastPathComponent, "index.html")
    }

    func testAFileTheManifestDoesNotListIsNeverServed() throws {
        try install(files: ["diagram.mmd"])
        try write("diagram.mmd"); try write("secret.txt"); try write("pins.json")
        XCTAssertNil(store.file(id, r: 1, name: "secret.txt"))
        XCTAssertNil(store.file(id, r: 1, name: "manifest.json"))
        XCTAssertNil(store.file(id, r: 1, name: "pins.json"))
    }

    func testAListedFileThatIsMissingIsNil() throws {
        try install(files: ["diagram.mmd"])
        XCTAssertNil(store.file(id, r: 1, name: "diagram.mmd"))
    }

    func testDotDotAndAbsolutePathsAreRefusedEvenWhenListed() throws {
        let sneaky = ["../r2/x", "export/../diagram.mmd", "/etc/hosts", "./diagram.mmd", "a//b", "", "export/", "..", "a\0b"]
        try install(files: sneaky + ["diagram.mmd"])
        try write("diagram.mmd")
        try write("x", in: tape.revisionDirectory(id, r: 2))
        for name in sneaky { XCTAssertNil(store.file(id, r: 1, name: name), name) }
    }

    func testASymlinkPointingOutIsRefusedEvenWhenListed() throws {
        try install(files: ["leak.txt"])
        try Data("secret".utf8).write(to: outside.appendingPathComponent("target.txt"))
        try FileManager.default.createSymbolicLink(at: rev.appendingPathComponent("leak.txt"),
                                                   withDestinationURL: outside.appendingPathComponent("target.txt"))
        XCTAssertNil(store.file(id, r: 1, name: "leak.txt"))
    }

    func testASymlinkInsideTheRevisionIsRefusedToo() throws {
        try install(files: ["alias.txt"])
        try write("real.txt")
        try FileManager.default.createSymbolicLink(at: rev.appendingPathComponent("alias.txt"),
                                                   withDestinationURL: rev.appendingPathComponent("real.txt"))
        XCTAssertNil(store.file(id, r: 1, name: "alias.txt"))
    }

    func testAListedFileUnderASymlinkedDirectoryIsRefused() throws {
        try install(files: ["export/index.html"])
        try Data("secret".utf8).write(to: outside.appendingPathComponent("index.html"))
        try FileManager.default.createSymbolicLink(at: rev.appendingPathComponent("export"), withDestinationURL: outside)
        XCTAssertNil(store.file(id, r: 1, name: "export/index.html"))
    }

    func testAFifoIsRefusedAndDoesNotBlock() throws {
        try install(files: ["pipe"])
        XCTAssertEqual(mkfifo(rev.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertNil(store.file(id, r: 1, name: "pipe"))
    }

    func testADirectoryNamedInTheManifestIsRefused() throws {
        try install(files: ["export"])
        try FileManager.default.createDirectory(at: rev.appendingPathComponent("export"), withIntermediateDirectories: true)
        XCTAssertNil(store.file(id, r: 1, name: "export"))
    }

    func testASymlinkedRevisionFolderIsRefused() throws {
        try install(files: ["a.txt"], r: 1)
        try write("a.txt")
        let linked = tape.revisionDirectory(id, r: 2)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: rev)
        XCTAssertNil(store.file(id, r: 2, name: "a.txt"))
        XCTAssertNil(store.revision(id, r: 2))
    }
}
