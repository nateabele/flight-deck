import XCTest
import IntakeKit

/// The registry is a repo file planning agents read and planning releases write. These tests
/// pin what routing leans on: a new project sees the seed set without a write, a proposal that
/// names an existing kind reuses it, and a file the store cannot read is never overwritten.
final class KindRegistryStoreTests: XCTestCase {
    private var project: URL!
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private var store: KindRegistryStore!

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("KindRegistryStoreTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let at = self.at
        store = KindRegistryStore(now: { at })
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private var file: URL { KindRegistryStore.fileURL(project: project) }

    private func proposal(_ name: String, _ dims: [String: Double] = ["test-authoring": 0.8, "agentic-coding": 0.3]) -> TaskKind {
        TaskKind(id: KindID.normalized(name), name: name, description: "Write or update snapshot/golden-file tests",
                 dimensions: dims, origin: .planning, status: .active, createdAt: at)
    }

    func testANewProjectSeesTheSeedSetWithoutAWrite() throws {
        XCTAssertEqual(try store.kinds(project: project).map(\.id), SeedKinds.all(createdAt: at).map(\.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAProposalIsWrittenBesideTheSeeds() throws {
        let added = try store.propose(proposal("Snapshot Tests"), project: project)
        XCTAssertEqual(added.id, "snapshot-tests")
        XCTAssertEqual(added.origin, .planning)
        let kinds = try store.kinds(project: project)
        XCTAssertEqual(kinds.count, SeedKinds.all(createdAt: at).count + 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(file.path, project.appendingPathComponent(".flightdeck/kinds.json").path)
    }

    func testAProposalWhoseNameNormalizesToAnExistingKindReusesIt() throws {
        _ = try store.propose(proposal("Snapshot Tests"), project: project)
        let again = try store.propose(proposal("snapshot   tests!!"), project: project)
        XCTAssertEqual(again.id, "snapshot-tests")
        XCTAssertEqual(try store.kinds(project: project).filter { $0.id == "snapshot-tests" }.count, 1)
        let seed = try store.propose(proposal("TESTS"), project: project)
        XCTAssertEqual(seed.origin, .seed, "a proposal named like a seed kind is that seed kind")
    }

    func testAProposalWithNoUsableNameIsRefusedAndWritesNothing() {
        XCTAssertThrowsError(try store.propose(proposal("!!!"), project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .invalid(.emptyName))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAProposalWithAnUnknownDimensionIsRefused() {
        XCTAssertThrowsError(try store.propose(proposal("Vibes", ["vibes": 0.9]), project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .invalid(.unknownDimension("vibes")))
        }
    }

    func testRenameKeepsTheId() throws {
        try store.rename("algorithm", to: "Algorithms and data structures", project: project)
        let k = try XCTUnwrap(try store.kinds(project: project).first { $0.id == "algorithm" })
        XCTAssertEqual(k.name, "Algorithms and data structures")
        XCTAssertThrowsError(try store.rename("nope", to: "x", project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .unknownKind("nope"))
        }
    }

    func testReweightValidates() throws {
        try store.reweight("docs", dimensions: ["docs-prose": 0.7], project: project)
        XCTAssertEqual(try store.kinds(project: project).first { $0.id == "docs" }?.dimensions, ["docs-prose": 0.7])
        XCTAssertThrowsError(try store.reweight("docs", dimensions: ["docs-prose": 1.4], project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .invalid(.weightOutOfRange("docs-prose", 1.4)))
        }
    }

    func testMergeMarksTheKindMergedAndRefusesBadTargets() throws {
        _ = try store.propose(proposal("Snapshot Tests"), project: project)
        try store.merge("snapshot-tests", into: "tests", project: project)
        let kinds = try store.kinds(project: project)
        XCTAssertEqual(kinds.first { $0.id == "snapshot-tests" }?.status, .merged(into: "tests"))
        XCTAssertEqual(KindResolution.resolve("snapshot-tests", in: kinds)?.id, "tests")
        XCTAssertThrowsError(try store.merge("tests", into: "tests", project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .mergeIntoSelf("tests"))
        }
        XCTAssertThrowsError(try store.merge("docs", into: "snapshot-tests", project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .mergeIntoMerged("snapshot-tests"))
        }
    }

    func testAnUnreadableFileThrowsAndIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("{\"v\":1,\"kinds\":[".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try store.kinds(project: project))
        XCTAssertThrowsError(try store.propose(proposal("Snapshot Tests"), project: project))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testANewerFileIsRefused() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"v":2,"kinds":[]}"#.utf8).write(to: file)
        XCTAssertThrowsError(try store.kinds(project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .newerVersion(2))
        }
    }

    func testTheSharedFixtureReads() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try L3Fixtures.data("kinds").write(to: file)
        let kinds = try store.kinds(project: project)
        XCTAssertEqual(kinds.map(\.id), ["tests", "snapshot-tests", "golden-tests", "algorithm"])
    }

    func testPromptKindsIsSeedsForANewProjectAndEmptyForABrokenFile() throws {
        XCTAssertEqual(KindRegistryStore.promptKinds(project: project).count, SeedKinds.all(createdAt: at).count)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: file)
        XCTAssertEqual(KindRegistryStore.promptKinds(project: project), [])
    }

    func testItIsTheContractsKindRegistry() throws {
        let registry: any KindRegistry = store
        XCTAssertFalse(try registry.kinds(project: project).isEmpty)
    }
}
