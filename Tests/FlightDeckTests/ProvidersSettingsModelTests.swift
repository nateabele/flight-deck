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

    /// A model whose first resolve has landed.
    private func model(repo: URL? = nil) async -> ProvidersSettingsModel {
        let m = unsettledModel(repo: repo)
        await m.settle()
        return m
    }

    private func unsettledModel(repo: URL? = nil) -> ProvidersSettingsModel {
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

    func testBundledAndUserRowsAreUsableWithASourceCaption() async throws {
        try write(bundled, folder: "b", id: "b", name: "Bundled one")
        try write(user, folder: "u", id: "u", name: "Mine")
        let rows = await model().rows
        XCTAssertEqual(rows.map(\.name), ["Bundled one", "Mine"])
        XCTAssertEqual(rows[0].sourceCaption, "Built in · v1.0.0")
        XCTAssertEqual(rows[1].sourceCaption, "Yours · v1.0.0")
        XCTAssertTrue(rows.allSatisfy { $0.status == .none && $0.isEnabled && $0.canToggle })
    }

    func testToggleOffPersistsAndSurvivesANewModel() async throws {
        try write(user, folder: "u", id: "u")
        let m = await model()
        m.setEnabled(m.key("u"), false)
        await m.settle()
        XCTAssertFalse(m.rows[0].isEnabled)
        let m1 = await model()
        XCTAssertFalse(m1.rows[0].isEnabled)
        m.setEnabled(m.key("u"), true)
        await m.settle()
        let m2 = await model()
        XCTAssertTrue(m2.rows[0].isEnabled)
    }

    func testRepoGeneratorProviderNeedsApprovalUntilApproved() async throws {
        try write(repoRoot, folder: "g", id: "g", name: "Gen", generator: true)
        let m = await model(repo: repo)
        let row = try XCTUnwrap(m.rows.first)
        XCTAssertEqual(row.status, .needsApproval(command: "python3 gen.py"))
        XCTAssertTrue(row.canApprove)
        XCTAssertFalse(row.canToggle, "an unapproved generator cannot be switched on")
        XCTAssertEqual(row.sourceCaption, "From my-repo · v1.0.0")
        m.approve(m.key("g"))
        await m.settle()
        XCTAssertEqual(m.rows[0].status, .approved)
        XCTAssertFalse(m.rows[0].canApprove)
        XCTAssertTrue(m.rows[0].canToggle)
    }

    func testChangingAnApprovedProviderAsksAgain() async throws {
        let dir = try write(repoRoot, folder: "g", id: "g", generator: true)
        let m = await model(repo: repo)
        m.approve(m.key("g"))
        await m.settle()
        try Data("print(2)".utf8).write(to: dir.appendingPathComponent("gen.py"))
        m.refresh()
        await m.settle()
        XCTAssertTrue(m.rows[0].canApprove)
    }

    func testDataOnlyRepoProviderNeedsNoApproval() async throws {
        try write(repoRoot, folder: "d", id: "d")
        let loaded = await model(repo: repo)
        let row = try XCTUnwrap(loaded.rows.first)
        XCTAssertEqual(row.status, .none)
        XCTAssertEqual(row.sourceCaption, "From my-repo · data only · v1.0.0")
        XCTAssertTrue(row.canToggle)
    }

    func testNewerContractReadsNeedsANewerFlightDeck() async throws {
        try write(user, folder: "n", id: "n", contract: 2)
        let loaded = await model()
        let row = try XCTUnwrap(loaded.rows.first)
        XCTAssertEqual(row.status, .needsNewerFlightDeck)
        XCTAssertFalse(row.canToggle)
        XCTAssertFalse(row.canApprove)
    }

    func testBrokenProviderShowsItsReasonAndCannotBeEnabled() async throws {
        try write(user, folder: "bad", id: "bad", body: "id = \"bad\"\nname = \"Bad\"\n")
        let loaded = await model()
        let row = try XCTUnwrap(loaded.rows.first)
        guard case .broken(let reason) = row.status else { return XCTFail("\(row.status)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(row.canToggle)
    }

    func testRepoCaptionNamesTheRepoAndSaysWhenThereIsNone() async throws {
        let m3 = await model(repo: repo)
        XCTAssertEqual(m3.repoCaption, "Repo providers come from my-repo (.flightdeck/visual-providers).")
        let m4 = await model()
        XCTAssertEqual(m4.repoCaption, "No project is selected, so repo providers are not shown.")
    }

    func testNoRepoMeansNoRepoRows() async throws {
        try write(repoRoot, folder: "d", id: "d")
        let m5 = await model()
        XCTAssertTrue(m5.rows.isEmpty)
    }

    func testCorruptTrustFileIsExplainedAndMoveAsideRecovers() async throws {
        try write(repoRoot, folder: "g", id: "g", generator: true)
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        let m = await model(repo: repo)
        XCTAssertNotNil(m.trustProblem)
        XCTAssertTrue(m.trustProblem?.contains("Approvals") == true)
        m.approve(m.key("g"))
        await m.settle()
        XCTAssertNotNil(m.trustProblem, "approve refuses over a corrupt file")
        XCTAssertFalse(m.rows[0].canApprove)
        m.moveTrustFileAside()
        await m.settle()
        XCTAssertNil(m.trustProblem)
        m.approve(m.key("g"))
        await m.settle()
        XCTAssertEqual(m.rows[0].status, .approved)
        let names = try FileManager.default.contentsOfDirectory(atPath: trustDir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("provider-trust.corrupt-") })
    }

    func testTrustStoreReportsUnreadableOnlyForACorruptFile() async throws {
        let store = ProviderTrustStore(directory: trustDir)
        XCTAssertFalse(store.isUnreadable, "a missing file is simply empty")
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        XCTAssertFalse(store.isUnreadable)
        try Data("nope".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        XCTAssertTrue(store.isUnreadable)
    }

    // MARK: Fix round 1

    func testApproveIsOffWhileTheTrustFileIsCorrupt() async throws {
        try write(repoRoot, folder: "g", id: "g", generator: true)
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        let m = await model(repo: repo)
        XCTAssertFalse(m.rows[0].canApprove)
        m.approve(m.key("g"))
        await m.settle()
        XCTAssertNotNil(m.approvalError, "a refused approval is never silent")
        XCTAssertFalse(m.approvalError?.contains("Swift") ?? false)
    }

    func testASwitchOnABundledProviderDoesNotReachARepoProviderOfTheSameID() async throws {
        try write(bundled, folder: "d", id: "diagrams", name: "Bundled diagrams")
        defaults.set(["bundled:diagrams"], forKey: ProvidersSettingsModel.disabledKey)
        let m6 = await model()
        XCTAssertFalse(try XCTUnwrap(m6.rows.first).isEnabled)
        // The repo's own diagrams wins in that repo and is not switched off by the bundled entry.
        try write(repoRoot, folder: "d", id: "diagrams", name: "Repo diagrams")
        let rows = await model(repo: repo).rows
        XCTAssertEqual(rows.map(\.name), ["Repo diagrams"])
        XCTAssertTrue(rows[0].isEnabled)
    }

    func testBrokenRepoProviderBesideAGoodBundledOneWithTheSameID() async throws {
        try write(bundled, folder: "x", id: "x", name: "Good")
        try write(repoRoot, folder: "x", id: "x", body: "id = \"x\"\nname = \"Bad\"\n")
        let m = await model(repo: repo)
        XCTAssertEqual(m.rows.count, 2)
        XCTAssertEqual(Set(m.rows.map(\.id)).count, 2)
        let bad = try XCTUnwrap(m.rows.first { if case .broken = $0.status { return true } else { return false } })
        m.setEnabled(bad.id, false)
        await m.settle()
        XCTAssertTrue(try XCTUnwrap(m.rows.first { $0.sourceCaption.hasPrefix("Built in") }).isEnabled)
    }

    func testV1DisabledIDsMigrateToBundledAndUserEntries() async throws {
        try write(bundled, folder: "b", id: "b")
        try write(user, folder: "u", id: "u")
        defaults.set(["b", "u"], forKey: "visualProviders.disabled.v1")
        let rows = await model().rows
        XCTAssertEqual(rows.map(\.isEnabled), [false, false])
        XCTAssertEqual(defaults.stringArray(forKey: ProvidersSettingsModel.disabledKey) ?? [],
                       ["bundled:b", "bundled:u", "user:b", "user:u"], "no repo entry comes from v1")
    }

    func testIsEnabledHelperCombinesUsabilityAndTheOffList() async throws {
        try write(user, folder: "u", id: "u")
        try write(repoRoot, folder: "g", id: "g", generator: true)
        let all = ProviderRegistry(userRoot: user, bundledRoot: bundled,
                                   trustStore: ProviderTrustStore(directory: trustDir)).resolve(repo: repo)
        let u = try XCTUnwrap(all.first { $0.id == "u" }), g = try XCTUnwrap(all.first { $0.id == "g" })
        XCTAssertTrue(ProviderRegistry.isEnabled(u, disabled: []))
        XCTAssertFalse(ProviderRegistry.isEnabled(u, disabled: ["user:u"]))
        XCTAssertTrue(ProviderRegistry.isEnabled(u, disabled: ["bundled:u", "repo:u"]))
        XCTAssertFalse(ProviderRegistry.isEnabled(g, disabled: []), "needs approval")
    }

    func testAProviderTheUserTurnedOffReadsOff() async throws {
        try write(user, folder: "u", id: "u")
        let m = await model()
        m.setEnabled(m.key("u"), false)
        await m.settle()
        XCTAssertEqual(m.rows[0].status, .off)
    }

    func testMoveAsideRefusesAReadableFileAndReportsFailure() async throws {
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        let store = ProviderTrustStore(directory: trustDir)
        XCTAssertThrowsError(try store.moveAside()) { XCTAssertEqual($0 as? ProviderTrustStore.StoreError, .fileIsReadable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trustDir.appendingPathComponent("provider-trust.json").path))
        let m = await model(repo: repo)
        m.moveTrustFileAside()
        await m.settle()
        XCTAssertNotNil(m.approvalError)
    }

    func testBannerCopyIsShort() async throws {
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: trustDir.appendingPathComponent("provider-trust.json"))
        let m7 = await model()
        XCTAssertLessThan(m7.trustProblem?.count ?? 999, 160)
    }

    // MARK: Final review

    /// A repo can hold a provider whose files take seconds to read; Settings must not freeze on
    /// them. The model is built and returned before any provider is resolved, the resolve runs
    /// off the main actor, and the rows land on main afterwards.
    func testResolvingRunsOffTheMainActorAndPublishesOnMain() async throws {
        try write(user, folder: "u", id: "u", name: "Mine")
        let m = unsettledModel()
        XCTAssertTrue(m.isLoading, "the model is returned before it has looked")
        XCTAssertTrue(m.rows.isEmpty, "init resolved on the main actor")
        await m.settle()
        XCTAssertFalse(m.isLoading)
        XCTAssertEqual(m.rows.map(\.name), ["Mine"])
        XCTAssertEqual(m.lastResolveWasOnMainThread, false)
    }
}

extension ProvidersSettingsModel {
    /// The row id of the one row with this provider id.
    func key(_ providerID: String) -> String { rows.first { $0.providerID == providerID }!.id }
}
