import HostKit
import XCTest
@testable import FlightDeck

/// The Providers section's row states, over temp folders and a private UserDefaults suite.
@MainActor
final class ProvidersSettingsModelTests: XCTestCase {
    private var tmp: URL!
    private var repo: URL!
    private var user: URL!
    private var bundled: URL!
    private var trustDir: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ProvidersSettingsModelTests-\(UUID().uuidString)")
        repo = tmp.appendingPathComponent("my-repo")
        user = tmp.appendingPathComponent("user")
        bundled = tmp.appendingPathComponent("bundled")
        trustDir = tmp.appendingPathComponent("trust")
        let dirs: [URL] = [repo.appendingPathComponent(ProviderRegistry.repoSubpath), user, bundled]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        suite = "ProvidersSettingsModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func model(repo: URL? = nil) -> ProvidersSettingsModel {
        ProvidersSettingsModel(
            registry: ProviderRegistry(userRoot: user, bundledRoot: bundled,
                                       trustStore: ProviderTrustStore(directory: trustDir)),
            repo: repo, defaults: defaults)
    }

    @discardableResult
    private func write(_ root: URL, folder: String, id: String, name: String = "P",
                       generator: Bool = false, contract: Int = 1, body: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var toml = body ?? """
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

    private var repoRoot: URL { repo.appendingPathComponent(ProviderRegistry.repoSubpath) }

    func testBundledAndUserRowsAreUsableWithASourceCaption() throws {
        try write(bundled, folder: "b", id: "b", name: "Bundled one")
        try write(user, folder: "u", id: "u", name: "Mine")
        let rows = model().rows
        XCTAssertEqual(rows.map(\.name), ["Bundled one", "Mine"])
        XCTAssertEqual(rows[0].sourceCaption, "Built in · v1.0.0")
        XCTAssertEqual(rows[1].sourceCaption, "Yours · v1.0.0")
        XCTAssertTrue(rows.allSatisfy { $0.status == .none && $0.isEnabled && $0.canToggle })
    }

    func testToggleOffPersistsAndSurvivesANewModel() throws {
        try write(user, folder: "u", id: "u")
        let m = model()
        m.setEnabled("u", false)
        XCTAssertFalse(m.rows[0].isEnabled)
        XCTAssertFalse(model().rows[0].isEnabled)
        m.setEnabled("u", true)
        XCTAssertTrue(model().rows[0].isEnabled)
    }

    func testRepoGeneratorProviderNeedsApprovalUntilApproved() throws {
        try write(repoRoot, folder: "g", id: "g", name: "Gen", generator: true)
        let m = model(repo: repo)
        let row = try XCTUnwrap(m.rows.first)
        XCTAssertEqual(row.status, .needsApproval(command: "python3 gen.py"))
        XCTAssertTrue(row.canApprove)
        XCTAssertFalse(row.canToggle, "an unapproved generator cannot be switched on")
        XCTAssertEqual(row.sourceCaption, "From my-repo · v1.0.0")
        m.approve("g")
        XCTAssertEqual(m.rows[0].status, .approved)
        XCTAssertFalse(m.rows[0].canApprove)
        XCTAssertTrue(m.rows[0].canToggle)
    }

    func testChangingAnApprovedProviderAsksAgain() throws {
        let dir = try write(repoRoot, folder: "g", id: "g", generator: true)
        let m = model(repo: repo)
        m.approve("g")
        try Data("print(2)".utf8).write(to: dir.appendingPathComponent("gen.py"))
        m.refresh()
        XCTAssertTrue(m.rows[0].canApprove)
    }

    func testDataOnlyRepoProviderNeedsNoApproval() throws {
        try write(repoRoot, folder: "d", id: "d")
        let row = try XCTUnwrap(model(repo: repo).rows.first)
        XCTAssertEqual(row.status, .none)
        XCTAssertEqual(row.sourceCaption, "From my-repo · data only · v1.0.0")
        XCTAssertTrue(row.canToggle)
    }

    func testNewerContractReadsNeedsANewerFlightDeck() throws {
        try write(user, folder: "n", id: "n", contract: 2)
        let row = try XCTUnwrap(model().rows.first)
        XCTAssertEqual(row.status, .needsNewerFlightDeck)
        XCTAssertFalse(row.canToggle)
        XCTAssertFalse(row.canApprove)
    }

    func testBrokenProviderShowsItsReasonAndCannotBeEnabled() throws {
        try write(user, folder: "bad", id: "bad", body: "id = \"bad\"\nname = \"Bad\"\n")
        let row = try XCTUnwrap(model().rows.first)
        guard case .broken(let reason) = row.status else { return XCTFail("\(row.status)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(row.canToggle)
    }

    func testRepoCaptionNamesTheRepoAndSaysWhenThereIsNone() throws {
        XCTAssertEqual(model(repo: repo).repoCaption, "Repo providers come from my-repo (.flightdeck/visual-providers).")
        XCTAssertEqual(model().repoCaption, "No project is selected, so repo providers are not shown.")
    }

    func testNoRepoMeansNoRepoRows() throws {
        try write(repoRoot, folder: "d", id: "d")
        XCTAssertTrue(model().rows.isEmpty)
    }

    func testCorruptTrustFileIsExplainedAndMoveAsideRecovers() throws {
        try write(repoRoot, folder: "g", id: "g", generator: true)
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        let m = model(repo: repo)
        XCTAssertNotNil(m.trustProblem)
        XCTAssertTrue(m.trustProblem?.contains("Approvals") == true)
        m.approve("g")
        XCTAssertNotNil(m.trustProblem, "approve refuses over a corrupt file")
        XCTAssertTrue(m.rows[0].canApprove)
        m.moveTrustFileAside()
        XCTAssertNil(m.trustProblem)
        m.approve("g")
        XCTAssertEqual(m.rows[0].status, .approved)
        let names = try FileManager.default.contentsOfDirectory(atPath: trustDir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("provider-trust.corrupt-") })
    }

    func testTrustStoreReportsUnreadableOnlyForACorruptFile() throws {
        let store = ProviderTrustStore(directory: trustDir)
        XCTAssertFalse(store.isUnreadable, "a missing file is simply empty")
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        XCTAssertFalse(store.isUnreadable)
        try Data("nope".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        XCTAssertTrue(store.isUnreadable)
    }
}
