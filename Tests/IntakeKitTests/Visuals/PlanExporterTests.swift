import XCTest
import CryptoKit
@testable import IntakeKit

/// An in-memory store, so the exporter is tested without a disk.
private struct FakeStore: VisualStoreReading {
    var states: [VisualID: BlockState] = [:]
    var revisions: [RevisionRef: VisualManifest] = [:]
    var bytes: [String: Data] = [:]   // "<id>/<r>/<name>"
    /// Answers every read with an empty slice while the file claims to be longer: a broken store.
    var stall = false

    func visuals() -> [VisualID] { states.keys.sorted() }
    func blockState(_ id: VisualID) -> BlockState? { states[id] }
    func blockState(_ id: VisualID, checkpoint: Int) -> BlockState? { nil }
    func revisions(_ id: VisualID) -> [Int] { revisions.keys.filter { $0.visualID == id }.map(\.r).sorted() }
    func revision(_ id: VisualID, r: Int) -> VisualRevision? {
        revisions[RevisionRef(visualID: id, r: r)].map { VisualRevision(id: id, r: r, manifest: $0) }
    }
    func read(_ id: VisualID, r: Int, name: String, offset: Int64, limit: Int) -> VisualFileSlice? {
        guard let m = revisions[RevisionRef(visualID: id, r: r)], m.files.contains(where: { $0.path == name }),
              let d = bytes["\(id.rawValue)/\(r)/\(name)"], offset >= 0, limit >= 0, offset <= Int64(d.count) else { return nil }
        if stall { return VisualFileSlice(data: Data(), size: Int64(d.count)) }
        return VisualFileSlice(data: d.dropFirst(Int(offset)).prefix(limit), size: Int64(d.count))
    }
}

final class PlanExporterTests: XCTestCase {
    private let vid = VisualID(rawValue: "pairing")!

    private func entry(_ p: String, _ d: Data? = nil) -> VisualFileEntry {
        let data = d ?? Data("bytes:\(p)".utf8)
        return VisualFileEntry(path: p, size: Int64(data.count),
                               sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    /// Replaces a primary file's bytes and keeps the manifest's size and hash true to them.
    private func setBytes(_ s: inout FakeStore, _ name: String, _ d: Data) {
        s.bytes["pairing/2/\(name)"] = d
        let ref = RevisionRef(visualID: vid, r: 2)
        var m = s.revisions[ref]!
        m.files = m.files.map { $0.path == name ? entry(name, d) : $0 }
        s.revisions[ref] = m
    }

    private func store(primary: Int = 2, alternates: [Int] = [1]) -> FakeStore {
        var s = FakeStore()
        let reps = (alternates + [primary]).map { RevisionRef(visualID: vid, r: $0) }
        s.states[vid] = BlockState(representations: reps, primary: RevisionRef(visualID: vid, r: primary))
        let files = ["diagram.mmd", "snapshot@default-1x.png", "snapshot@empty-1x.png", "pins.json"].map { entry($0) }
        s.revisions[RevisionRef(visualID: vid, r: primary)] = VisualManifest(
            provider: "mermaid", providerVersion: "1", kind: "diagram", title: "Pairing", entry: "diagram.mmd",
            states: ["default", "empty"], sizes: ["1x"], madeOnCheckpoint: 3, madeBy: .you, primary: true, files: files)
        for a in alternates {
            s.revisions[RevisionRef(visualID: vid, r: a)] = VisualManifest(
                provider: "mermaid", providerVersion: "1", kind: "diagram", title: "Alt", entry: "diagram.mmd",
                madeOnCheckpoint: 2, madeBy: .you, files: [entry("diagram.mmd")])
            s.bytes["pairing/\(a)/diagram.mmd"] = Data("ALT SOURCE".utf8)
        }
        for f in files { s.bytes["pairing/\(primary)/\(f.path)"] = Data("bytes:\(f.path)".utf8) }
        return s
    }

    private let plan = """
    # Title

    Intro.

    ```fd-visual id=pairing
    Pairing handshake
    ```

    After.
    """

    private func export(_ s: FakeStore, plan: String? = nil, slug: String = "my-plan") throws -> PlanExport {
        try PlanExporter.export(plan: plan ?? self.plan, slug: slug, intakeID: "intake-1", store: s, blockStates: [:])
    }

    func testPlanFencesBecomeAnImageAndAFolderLink() throws {
        let out = try export(store())
        let md = String(decoding: try XCTUnwrap(out.file("plan.md")).data, as: UTF8.self)
        XCTAssertTrue(md.contains("![Pairing handshake](visuals/pairing/snapshot@default-1x.png)"), md)
        XCTAssertTrue(md.contains("[Pairing handshake: files](visuals/pairing/)"), md)
        XCTAssertFalse(md.contains("fd-visual"))
        XCTAssertTrue(md.contains("Intro.") && md.contains("After."))
    }

    func testPathsAndContents() throws {
        let out = try export(store())
        XCTAssertEqual(out.directory, "docs/plans/my-plan")
        let paths = Set(out.files.map(\.path))
        XCTAssertEqual(paths, [
            "plan.md", ".flightdeck-intake",
            "visuals/pairing/diagram.mmd", "visuals/pairing/snapshot@default-1x.png",
            "visuals/pairing/snapshot@empty-1x.png", "visuals/pairing/pins.json", "visuals/pairing/README.md",
            "visuals/pairing/_unused-alternates/1/README.md"])
        XCTAssertEqual(out.file("visuals/pairing/diagram.mmd")?.data, Data("bytes:diagram.mmd".utf8))
        XCTAssertEqual(out.file(".flightdeck-intake")?.data, Data("intake-1\n".utf8))
    }

    func testAlternatesReadmeIsExactAndTheAlternatesBytesAreNotCopied() throws {
        let out = try export(store())
        XCTAssertEqual(out.file("visuals/pairing/_unused-alternates/1/README.md")?.data,
                       Data("Not chosen. Do not implement from these.\n".utf8))
        XCTAssertFalse(out.files.contains { String(decoding: $0.data, as: UTF8.self).contains("ALT SOURCE") })
    }

    func testVisualReadmeNamesKindStatesAndHowToOpen() throws {
        let readme = String(decoding: try XCTUnwrap(export(store()).file("visuals/pairing/README.md")).data, as: UTF8.self)
        XCTAssertTrue(readme.contains("diagram"))
        XCTAssertTrue(readme.contains("default") && readme.contains("empty"))
        XCTAssertTrue(readme.lowercased().contains("open"))
    }

    func testFilesLargerThanOneChunkAreReadWhole() throws {
        var s = store()
        let big = Data((0..<(PlanExporter.chunkBytes * 2 + 17)).map { UInt8($0 % 251) })
        setBytes(&s, "diagram.mmd", big)
        XCTAssertEqual(try export(s).file("visuals/pairing/diagram.mmd")?.data, big)
    }

    func testAFileTheStoreWillNotReadFailsTheExport() {
        var s = store()
        s.bytes["pairing/2/diagram.mmd"] = nil
        XCTAssertThrowsError(try export(s)) { XCTAssertEqual($0 as? PlanExporter.Failure, .unreadable(visual: "pairing", path: "diagram.mmd")) }
    }

    func testBytesThatDoNotMatchTheManifestHashAreRefused() {
        var s = store()
        s.bytes["pairing/2/diagram.mmd"] = Data("tampered".utf8)
        XCTAssertThrowsError(try export(s)) { XCTAssertEqual($0 as? PlanExporter.Failure, .unreadable(visual: "pairing", path: "diagram.mmd")) }
    }

    func testAnEmptySliceBeforeTheEndIsAnErrorNotAShortFile() {
        var s = store()
        s.stall = true
        XCTAssertThrowsError(try export(s)) { XCTAssertEqual($0 as? PlanExporter.Failure, .unreadable(visual: "pairing", path: "diagram.mmd")) }
    }

    func testTheDefaultSnapshotPrefersTheStateNamedDefault() throws {
        var s = store()
        let ref = RevisionRef(visualID: vid, r: 2)
        var m = s.revisions[ref]!
        m.states = ["empty", "default"]
        s.revisions[ref] = m
        let md = String(decoding: try XCTUnwrap(export(s).file("plan.md")).data, as: UTF8.self)
        XCTAssertTrue(md.contains("snapshot@default-1x.png"), md)
    }

    func testAManifestPathThatEscapesIsRefused() {
        var s = store()
        var m = s.revisions[RevisionRef(visualID: vid, r: 2)]!
        m.files.append(entry("../../evil"))
        s.revisions[RevisionRef(visualID: vid, r: 2)] = m
        XCTAssertThrowsError(try export(s)) { XCTAssertEqual($0 as? PlanExporter.Failure, .unsafePath("../../evil")) }
    }

    func testAMissingVisualLeavesANoteAndAWarning() throws {
        let out = try export(FakeStore(), plan: "```fd-visual id=ghost\nGhost\n```\n")
        let md = String(decoding: try XCTUnwrap(out.file("plan.md")).data, as: UTF8.self)
        XCTAssertTrue(md.contains("ghost"))
        XCTAssertFalse(md.contains("fd-visual"))
        XCTAssertEqual(out.warnings.count, 1)
        XCTAssertNil(out.files.first { $0.path.hasPrefix("visuals/") })
    }

    func testOrdinaryCodeFencesAndInvalidIdsAreLeftAlone() throws {
        let src = "```swift\nlet x = 1\n```\n\n```fd-visual id=Bad/Id\nx\n```\n"
        let md = String(decoding: try XCTUnwrap(export(store(), plan: src).file("plan.md")).data, as: UTF8.self)
        XCTAssertEqual(md, src)
    }

    func testALongerFenceNestsAShorterOne() throws {
        let src = "````md\n```fd-visual id=pairing\ncaption\n```\n````\n"
        let md = String(decoding: try XCTUnwrap(export(store(), plan: src).file("plan.md")).data, as: UTF8.self)
        XCTAssertEqual(md, src, "an example inside a longer fence is not a visual")
    }

    func testTheSameVisualTwiceIsExportedOnce() throws {
        let src = plan + "\n\n```fd-visual id=pairing\nAgain\n```\n"
        let out = try export(store(), plan: src)
        XCTAssertEqual(out.files.filter { $0.path == "visuals/pairing/diagram.mmd" }.count, 1)
    }

    func testNoSnapshotMeansALinkOnly() throws {
        var s = store()
        var m = s.revisions[RevisionRef(visualID: vid, r: 2)]!
        m.files = [entry("diagram.mmd")]
        s.revisions[RevisionRef(visualID: vid, r: 2)] = m
        let md = String(decoding: try XCTUnwrap(export(s).file("plan.md")).data, as: UTF8.self)
        XCTAssertFalse(md.contains("!["))
        XCTAssertTrue(md.contains("(visuals/pairing/)"))
    }

    func testCommitMessageAndPreview() throws {
        let out = try export(store())
        XCTAssertEqual(out.commitMessage, "docs: plan my-plan for release")
        XCTAssertTrue(out.preview.paths.contains("docs/plans/my-plan/plan.md"))
        XCTAssertEqual(out.preview.commitMessage, out.commitMessage)
    }
}

final class PlanSlugTests: XCTestCase {
    func testSlugIsLowercaseSafe() {
        XCTAssertEqual(PlanExporter.slug(for: "Pairing: Phone & Mac  (v2)!"), "pairing-phone-mac-v2")
        XCTAssertEqual(PlanExporter.slug(for: "Café Ünïcode"), "cafe-unicode")
        XCTAssertEqual(PlanExporter.slug(for: "../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(PlanExporter.slug(for: "   "), "plan")
        XCTAssertEqual(PlanExporter.slug(for: "日本語"), "ri-ben-yu")
        XCTAssertEqual(PlanExporter.slug(for: "!!!"), "plan")
        XCTAssertLessThanOrEqual(PlanExporter.slug(for: String(repeating: "word ", count: 40)).count, 48)
        XCTAssertFalse(PlanExporter.slug(for: String(repeating: "word ", count: 40)).hasSuffix("-"))
    }

    func testWindowsReservedNamesGetASuffix() {
        for name in ["con", "PRN", "aux", "nul", "com1", "COM9", "lpt1", "lpt9"] {
            XCTAssertEqual(PlanExporter.slug(for: name), name.lowercased() + "-x", name)
        }
        XCTAssertEqual(PlanExporter.slug(for: "com10"), "com10")
        XCTAssertEqual(PlanExporter.slug(for: "console"), "console")
    }

    func testCollisionsAddTwoThenThree() {
        var owners: [String: SlugOwner] = ["pairing": .intake("other"), "pairing-2": .intake("another")]
        XCTAssertEqual(PlanExporter.resolveSlug(title: "Pairing", intakeID: "me") { owners[$0] ?? .free }, "pairing-3")
        owners["pairing-3"] = .unmarked
        XCTAssertEqual(PlanExporter.resolveSlug(title: "Pairing", intakeID: "me") { owners[$0] ?? .free }, "pairing-4")
    }

    func testAReReleaseKeepsItsOwnFolder() {
        let owners: [String: SlugOwner] = ["pairing": .intake("other"), "pairing-2": .intake("me")]
        XCTAssertEqual(PlanExporter.resolveSlug(title: "Pairing", intakeID: "me") { owners[$0] ?? .free }, "pairing-2")
    }

    func testADifferentIntakeNeverTakesOverAFolder() {
        let owners: [String: SlugOwner] = ["pairing": .intake("first")]
        XCTAssertEqual(PlanExporter.resolveSlug(title: "Pairing", intakeID: "second") { owners[$0] ?? .free }, "pairing-2")
    }

    func testAFolderWithNoMarkerBelongsToNoOne() {
        let owners: [String: SlugOwner] = ["pairing": .unmarked]
        XCTAssertEqual(PlanExporter.resolveSlug(title: "Pairing", intakeID: "me") { owners[$0] ?? .free }, "pairing-2")
    }
}

final class FidelityReferencesTests: XCTestCase {
    func testSectionTextIsExact() {
        let out = FidelityReferences.appending(to: "Do the thing.",
            refs: [VisualRef(visualID: "pairing", states: ["default", "empty", "error"])], slug: "my-plan")
        XCTAssertEqual(out, """
        Do the thing.

        Fidelity references (implement to match; don't redesign):
        - docs/plans/my-plan/visuals/pairing/ \u{2014} states: default, empty, error
        """)
    }
    func testNoStatesOmitsTheClauseAndNoRefsChangesNothing() {
        XCTAssertTrue(FidelityReferences.appending(to: "d", refs: [VisualRef(visualID: "a")], slug: "s")
            .hasSuffix("- docs/plans/s/visuals/a/"))
        XCTAssertEqual(FidelityReferences.appending(to: "d", refs: nil, slug: "s"), "d")
        XCTAssertEqual(FidelityReferences.appending(to: "d", refs: [], slug: "s"), "d")
        XCTAssertEqual(FidelityReferences.appending(to: "d", refs: [VisualRef(visualID: "a")], slug: nil), "d")
    }
}
