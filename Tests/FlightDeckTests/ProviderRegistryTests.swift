import HostKit
import XCTest
@testable import FlightDeck

/// Provider resolution order and the repo trust gate, over temp folders only.
final class ProviderRegistryTests: XCTestCase {
    private var tmp: URL!
    private var repo: URL!
    private var user: URL!
    private var bundled: URL!
    private var store: ProviderTrustStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderRegistryTests-\(UUID().uuidString)")
        repo = tmp.appendingPathComponent("repo")
        user = tmp.appendingPathComponent("user")
        bundled = tmp.appendingPathComponent("bundled")
        store = ProviderTrustStore(directory: tmp.appendingPathComponent("trust"))
        let roots: [URL] = [repo.appendingPathComponent(ProviderRegistry.repoSubpath), user, bundled]
        for dir in roots {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var registry: ProviderRegistry {
        ProviderRegistry(userRoot: user, bundledRoot: bundled, trustStore: store)
    }

    private var repoRoot: URL { repo.appendingPathComponent(ProviderRegistry.repoSubpath) }

    /// Writes a minimal valid provider; `generator` makes it one that runs code.
    @discardableResult
    private func write(_ root: URL, folder: String, id: String, name: String = "P",
                       generator: Bool = false, contract: Int = 1) throws -> URL {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var toml = """
        id = "\(id)"
        name = "\(name)"
        version = "1.0.0"
        contract = \(contract)

        [[kind]]
        id = "k"
        summary = "s"
        output = "html"
        entry = "k.html"
        instructions = "k.md"
        """
        if generator {
            toml += "\n\n[generator]\ncommand = [\"python3\", \"gen.py\"]\ntimeout = \"10s\"\n"
            try Data("print(1)".utf8).write(to: dir.appendingPathComponent("gen.py"))
        }
        try Data(toml.utf8).write(to: dir.appendingPathComponent("provider.toml"))
        try Data("do it".utf8).write(to: dir.appendingPathComponent("k.md"))
        return dir
    }

    private func find(_ list: [ResolvedProvider], _ id: String) -> ResolvedProvider? {
        list.first { $0.id == id }
    }

    func testBundledAndUserAreTrustedByTheirSource() throws {
        try write(bundled, folder: "b", id: "b")
        try write(user, folder: "u", id: "u")
        let list = registry.resolve(repo: repo)
        XCTAssertEqual(find(list, "b")?.trust, .bundled)
        XCTAssertEqual(find(list, "u")?.trust, .user)
        XCTAssertEqual(find(list, "u")?.source, .user)
    }

    func testPrecedenceRepoThenUserThenBundled() throws {
        try write(bundled, folder: "x", id: "same", name: "bundled")
        try write(user, folder: "x", id: "same", name: "user")
        XCTAssertEqual(find(registry.resolve(repo: nil), "same")?.manifest?.name, "user")
        try write(repoRoot, folder: "x", id: "same", name: "repo")
        let list = registry.resolve(repo: repo)
        XCTAssertEqual(list.filter { $0.id == "same" }.count, 1)
        XCTAssertEqual(find(list, "same")?.manifest?.name, "repo")
        XCTAssertEqual(find(list, "same")?.source, .repo)
    }

    func testRepoProviderShadowsInThatRepoOnly() throws {
        try write(bundled, folder: "x", id: "same", name: "bundled")
        try write(repoRoot, folder: "x", id: "same", name: "repo")
        let otherRepo = tmp.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRepo, withIntermediateDirectories: true)
        XCTAssertEqual(find(registry.resolve(repo: repo), "same")?.manifest?.name, "repo")
        XCTAssertEqual(find(registry.resolve(repo: otherRepo), "same")?.manifest?.name, "bundled")
        XCTAssertEqual(find(registry.resolve(repo: nil), "same")?.manifest?.name, "bundled")
    }

    func testRepoProviderWithoutGeneratorIsDataOnly() throws {
        try write(repoRoot, folder: "d", id: "d")
        let p = try XCTUnwrap(find(registry.resolve(repo: repo), "d"))
        XCTAssertEqual(p.trust, .repoDataOnly)
        XCTAssertTrue(p.isUsable)
    }

    func testRepoGeneratorNeedsApprovalThenIsApproved() throws {
        try write(repoRoot, folder: "g", id: "g", generator: true)
        var p = try XCTUnwrap(find(registry.resolve(repo: repo), "g"))
        XCTAssertEqual(p.trust, .repoNeedsApproval)
        XCTAssertFalse(p.isUsable)
        try registry.approve(p, shownDigest: try XCTUnwrap(p.digest), repo: repo)
        p = try XCTUnwrap(find(registry.resolve(repo: repo), "g"))
        XCTAssertEqual(p.trust, .repoApproved)
        XCTAssertTrue(p.isUsable)
    }

    func testOneChangedByteAfterApprovalNeedsApprovalAgain() throws {
        let dir = try write(repoRoot, folder: "g", id: "g", generator: true)
        let shown = try XCTUnwrap(find(registry.resolve(repo: repo), "g"))
        try registry.approve(shown, shownDigest: try XCTUnwrap(shown.digest), repo: repo)
        XCTAssertEqual(find(registry.resolve(repo: repo), "g")?.trust, .repoApproved)
        try Data("print(2)".utf8).write(to: dir.appendingPathComponent("gen.py"))
        XCTAssertEqual(find(registry.resolve(repo: repo), "g")?.trust, .repoNeedsApproval)
    }

    func testApprovalInOneRepoDoesNotApproveTheSameFolderInAnother() throws {
        try write(repoRoot, folder: "g", id: "g", generator: true)
        let shown = try XCTUnwrap(find(registry.resolve(repo: repo), "g"))
        try registry.approve(shown, shownDigest: try XCTUnwrap(shown.digest), repo: repo)
        let other = tmp.appendingPathComponent("other")
        try write(other.appendingPathComponent(ProviderRegistry.repoSubpath), folder: "g", id: "g", generator: true)
        XCTAssertEqual(find(registry.resolve(repo: other), "g")?.trust, .repoNeedsApproval)
    }

    func testParseErrorIsListedWithProblemsAndNeverUsed() throws {
        let dir = repoRoot.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("id = ".utf8).write(to: dir.appendingPathComponent("provider.toml"))
        let p = try XCTUnwrap(find(registry.resolve(repo: repo), "bad"))
        XCTAssertNil(p.manifest)
        XCTAssertEqual(p.trust, .unusable)
        XCTAssertFalse(p.isUsable)
        XCTAssertFalse(p.problems.isEmpty)
    }

    func testNewerContractIsListedAsNeedingANewerFlightDeck() throws {
        try write(user, folder: "n", id: "n", contract: 99)
        let p = try XCTUnwrap(find(registry.resolve(repo: nil), "n"))
        XCTAssertFalse(p.isUsable)
        XCTAssertTrue(p.needsNewerFlightDeck)
    }

    func testBrokenRepoProviderDoesNotShadowAGoodBundledOne() throws {
        try write(bundled, folder: "x", id: "x", name: "bundled")
        let dir = repoRoot.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("id = ".utf8).write(to: dir.appendingPathComponent("provider.toml"))
        let list = registry.resolve(repo: repo)
        XCTAssertEqual(list.filter { $0.id == "x" && $0.isUsable }.first?.manifest?.name, "bundled")
        XCTAssertEqual(list.filter { $0.id == "x" }.count, 2)
    }

    func testRepoGeneratorWithASymlinkIsUnusable() throws {
        let dir = try write(repoRoot, folder: "g", id: "g", generator: true)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("gen.py"))
        let p = try XCTUnwrap(find(registry.resolve(repo: repo), "g"))
        XCTAssertEqual(p.trust, .unusable)
        XCTAssertTrue(p.problems.contains { $0.message.contains("link") })
    }

    func testApproveRefusesWhenFolderChangedSinceShown() throws {
        let dir = try write(repoRoot, folder: "g", id: "g", generator: true)
        let shown = try XCTUnwrap(find(registry.resolve(repo: repo), "g"))
        try Data("print(666)".utf8).write(to: dir.appendingPathComponent("gen.py"))
        XCTAssertThrowsError(try registry.approve(shown, shownDigest: try XCTUnwrap(shown.digest), repo: repo)) {
            XCTAssertEqual($0 as? ProviderRegistry.ApprovalError, .changedSinceShown)
        }
        XCTAssertEqual(find(registry.resolve(repo: repo), "g")?.trust, .repoNeedsApproval)
    }
}
