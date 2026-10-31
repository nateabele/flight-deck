import XCTest
import IntakeKit

/// The visual-block shapes (P2a V0): what ThreadRunner writes under `visuals/`. Storage formats
/// from the day they land, so each must round-trip, tolerate an old or minimal file, and refuse
/// an id that could become a path.
final class VisualModelCodingTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try IntakeJSON.encoder.encode(value)
        XCTAssertEqual(try IntakeJSON.decoder.decode(T.self, from: data), value, file: file, line: line)
    }

    private let id = VisualID(rawValue: "pairing-handshake")!

    // MARK: - VisualID

    func testVisualIDCodesAsABareStringAndConvertsToThreadAnchorsString() throws {
        let data = try JSONEncoder().encode([id])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["pairing-handshake"]"#)
        XCTAssertEqual(try JSONDecoder().decode([VisualID].self, from: data), [id])
        // P1's anchor keeps its plain String; the id converts both ways without changing it.
        let anchor = ThreadAnchor(visualID: id.rawValue)
        XCTAssertEqual(anchor.visualID.flatMap(VisualID.init(rawValue:)), id)
    }

    func testAnIdThatCouldBecomeAPathIsRefused() throws {
        for bad in ["", ".", "..", "../x", "a/b", ".hidden", "a b", "é", String(repeating: "a", count: 65), "a\nb", "-a", "_a"] {
            XCTAssertNil(VisualID(rawValue: bad), bad)
            let json = try JSONEncoder().encode([bad])
            XCTAssertThrowsError(try JSONDecoder().decode([VisualID].self, from: json), bad)
        }
        for good in ["a", "pairing-handshake", "v1.2_final", String(repeating: "a", count: 64)] {
            XCTAssertNotNil(VisualID(rawValue: good), good)
        }
    }

    // MARK: - Manifest

    private var manifest: VisualManifest {
        VisualManifest(provider: "mermaid", providerVersion: "11.4.1", kind: "diagram", title: "Pairing handshake",
                       entry: "diagram.mmd", states: ["idle", "paired"], sizes: ["wide", "narrow"], pins: .node,
                       madeOnCheckpoint: 3, madeBy: .thread(ThreadID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)),
                       parent: 1, alternates: [VisualAlternate(revision: 2, kind: "canvas", reason: "closer to the comp", by: .you)],
                       primary: true)
    }

    func testManifestRoundTrips() throws {
        try roundTrip(manifest)
    }

    func testManifestKeysAreTheSpecsNames() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: IntakeJSON.encoder.encode(manifest)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["provider", "providerVersion", "kind", "title", "entry", "states", "sizes", "pins",
                                       "madeOnCheckpoint", "madeBy", "parent", "alternates", "primary", "files"])
        XCTAssertEqual(obj["pins"] as? String, "node")
    }

    /// A provider that writes only the essentials still loads; the rest default.
    func testAMinimalManifestLoadsWithDefaults() throws {
        let json = #"{"provider":"mermaid","providerVersion":"1","kind":"diagram","entry":"d.mmd","madeOnCheckpoint":1,"madeBy":{"kind":"round","id":"draft-0"}}"#
        let m = try IntakeJSON.decoder.decode(VisualManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.title, "")
        XCTAssertEqual(m.states, [])
        XCTAssertEqual(m.sizes, [])
        XCTAssertEqual(m.pins, .position)
        XCTAssertNil(m.parent)
        XCTAssertEqual(m.alternates, [])
        XCTAssertFalse(m.primary)
        XCTAssertEqual(m.madeBy, .round("draft-0"))
    }

    func testAKeyOrPinSchemeThisBuildDoesNotKnowDoesNotFailTheManifest() throws {
        let json = #"{"provider":"p","providerVersion":"1","kind":"k","entry":"e","pins":"hologram","madeOnCheckpoint":1,"madeBy":{"kind":"drone"},"future":{"x":1}}"#
        let m = try IntakeJSON.decoder.decode(VisualManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.pins, .unknown("hologram"))
        XCTAssertEqual(m.madeBy.kind, "drone")
        try roundTrip(m)
    }

    // MARK: - Block state and refs

    func testBlockStateRoundTripsAndNamesTheStarredRevision() throws {
        let a = RevisionRef(visualID: id, r: 1), b = RevisionRef(visualID: id, r: 2)
        let state = BlockState(representations: [a, b], primary: b)
        try roundTrip(state)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: IntakeJSON.encoder.encode(state)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["representations", "primary"])
    }

    func testRevisionExposesItsRef() {
        XCTAssertEqual(VisualRevision(id: id, r: 2, manifest: manifest).ref, RevisionRef(visualID: id, r: 2))
    }

    func testVisualRefStatesDefaultToNone() throws {
        let ref = try IntakeJSON.decoder.decode(VisualRef.self, from: Data(#"{"visualID":"x"}"#.utf8))
        XCTAssertEqual(ref, VisualRef(visualID: "x"))
        try roundTrip(VisualRef(visualID: "x", states: ["paired"]))
    }

    // MARK: - Paths

    func testTheStorePathsAreUnderVisualsAndRevisionsAreRN() {
        let store = TapeStore(intakeDirectory: URL(fileURLWithPath: "/tmp/i", isDirectory: true))
        XCTAssertEqual(store.visualsRoot.path, "/tmp/i/visuals")
        XCTAssertEqual(store.visualsDirectory(id).path, "/tmp/i/visuals/pairing-handshake")
        XCTAssertEqual(store.revisionDirectory(id, r: 3).path, "/tmp/i/visuals/pairing-handshake/r3")
    }

    func testTheEmptyStoreHasNothing() {
        let store: any VisualStoreReading = EmptyVisualStore()
        XCTAssertTrue(store.visuals().isEmpty)
        XCTAssertNil(store.blockState(id))
        XCTAssertNil(store.blockState(id, checkpoint: 1))
        XCTAssertTrue(store.revisions(id).isEmpty)
        XCTAssertNil(store.revision(id, r: 1))
        XCTAssertNil(store.file(id, r: 1, name: "manifest.json"))
    }

    // MARK: - Lowercase only (R-I5)

    /// On case-insensitive APFS `Foo` and `foo` would share a folder, so only one spelling exists.
    func testIdsAreLowercaseAsciiOnly() throws {
        for bad in ["Foo", "fOo", "PAIRING", "a.B"] {
            XCTAssertNil(VisualID(rawValue: bad), bad)
            XCTAssertThrowsError(try JSONDecoder().decode([VisualID].self, from: JSONEncoder().encode([bad])), bad)
        }
        for good in ["foo", "0a", "a.b_c-d", "v1.2"] { XCTAssertNotNil(VisualID(rawValue: good), good) }
    }

    // MARK: - Manifest files, per-checkpoint states, export folder

    func testAManifestListsItsFilesAndAnOldOneListsNone() throws {
        var m = manifest
        m.files = [VisualFileEntry(path: "diagram.mmd", size: 12, sha256: "ab"), VisualFileEntry(path: "export/index.html", size: 3, sha256: "cd")]
        try roundTrip(m)
        XCTAssertEqual(try IntakeJSON.decoder.decode(VisualManifest.self, from: IntakeJSON.encoder.encode(manifest)).files, [])
    }

    func testCheckpointBlockStatesCodeAsAnObjectKeyedByVisualID() throws {
        let b = RevisionRef(visualID: id, r: 2)
        let states = CheckpointBlockStates(states: [id: BlockState(representations: [b], primary: b)])
        try roundTrip(states)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: IntakeJSON.encoder.encode(states)) as? [String: Any])
        XCTAssertEqual(Array(obj.keys), ["pairing-handshake"], "an object, not Swift's array-of-pairs for non-string keys")
        // A key that is not a usable id fails loudly rather than becoming a path later.
        XCTAssertThrowsError(try IntakeJSON.decoder.decode(CheckpointBlockStates.self, from: Data(#"{"../x":{"representations":[],"primary":{"visualID":"a","r":1}}}"#.utf8)))
    }

    func testCheckpointVisualsAndExportPaths() {
        let store = TapeStore(intakeDirectory: URL(fileURLWithPath: "/tmp/i", isDirectory: true))
        XCTAssertEqual(store.checkpointVisualsURL(4).path, "/tmp/i/checkpoints/4/visuals.json")
        XCTAssertEqual(store.exportDirectory(id, r: 3).path, "/tmp/i/visuals/pairing-handshake/r3/export")
    }
}
