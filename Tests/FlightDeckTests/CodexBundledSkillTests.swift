import XCTest
@testable import FlightDeck

/// `CodexBundledSkill` copies a skill FOLDER into a codex home under the same `.flightdeck-managed`
/// digest contract `CodexDelegateSkill` always had. `DelegateSkillTests` and the peer-messaging
/// test pin the single-file behaviour; these pin what a folder adds.
final class CodexBundledSkillTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var source: URL!
    private let skill = CodexBundledSkill(name: "demo")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBundledSkillTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try put("skill v1", at: source.appendingPathComponent("SKILL.md"))
        try put("manifest v1", at: source.appendingPathComponent("templates/provider.toml"))
        try put("kind v1", at: source.appendingPathComponent("templates/kinds/example.md"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func installed(_ path: String) -> URL { home.appendingPathComponent("skills/flightdeck-demo/\(path)") }
    private func text(_ path: String) throws -> String { try String(contentsOf: installed(path), encoding: .utf8) }

    func testTheWholeFolderIsCopiedUnderThePrefixedName() throws {
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .installed)
        XCTAssertEqual(try text("SKILL.md"), "skill v1")
        XCTAssertEqual(try text("templates/provider.toml"), "manifest v1")
        XCTAssertEqual(try text("templates/kinds/example.md"), "kind v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed(".flightdeck-managed").path))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .current)
    }

    func testAUserEditToAnyFileKeepsTheWholeFolder() throws {
        _ = try skill.install(from: source, codexHome: home)
        try put("my kind", at: installed("templates/kinds/example.md"))
        try put("skill v2", at: source.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .userEdited)
        XCTAssertEqual(try text("templates/kinds/example.md"), "my kind")
        XCTAssertEqual(try text("SKILL.md"), "skill v1", "an edited folder is left whole, not half-refreshed")
    }

    func testAnExtraFileTheUserAddedIsAnEditAndSurvives() throws {
        _ = try skill.install(from: source, codexHome: home)
        try put("mine", at: installed("notes.md"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .userEdited)
        XCTAssertEqual(try text("notes.md"), "mine")
    }

    func testADeletedSkillFileStaysDeleted() throws {
        _ = try skill.install(from: source, codexHome: home)
        try FileManager.default.removeItem(at: installed("SKILL.md"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .userDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed("SKILL.md").path))
    }

    func testAnUntouchedInstallUpgradesAndDropsFilesTheNewVersionNoLongerShips() throws {
        _ = try skill.install(from: source, codexHome: home)
        try put("skill v2", at: source.appendingPathComponent("SKILL.md"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("templates/kinds/example.md"))
        try put("new asset", at: source.appendingPathComponent("templates/extra.md"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .refreshed)
        XCTAssertEqual(try text("SKILL.md"), "skill v2")
        XCTAssertEqual(try text("templates/extra.md"), "new asset")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed("templates/kinds/example.md").path))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .current)
    }

    /// A skill that shipped as one SKILL.md and now ships a folder: its old sidecar is the plain
    /// SHA-256 of that file, and the upgrade must still read it as ours.
    func testAnOldSingleFileInstallUpgradesToAFolder() throws {
        let old = Data("skill v0".utf8)
        try put("skill v0", at: installed("SKILL.md"))
        try put(CodexDelegateSkill.digest(old) + "\n", at: installed(".flightdeck-managed"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .refreshed)
        XCTAssertEqual(try text("templates/provider.toml"), "manifest v1")
    }

    func testAFolderWithoutASidecarIsTheUsersOwn() throws {
        try put("hand written", at: installed("SKILL.md"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .userOwned)
        XCTAssertEqual(try text("SKILL.md"), "hand written")
    }

    func testUninstallRemovesTheWholeFolderOnlyWhileUntouched() throws {
        _ = try skill.install(from: source, codexHome: home)
        try put("mine", at: installed("notes.md"))
        XCTAssertFalse(try skill.uninstall(home: home))
        try FileManager.default.removeItem(at: installed("notes.md"))
        XCTAssertTrue(try skill.uninstall(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed("SKILL.md").deletingLastPathComponent().path))
    }

    func testTheVisualProviderSkillShipsInTheBundleAsAFolder() throws {
        let folder = try XCTUnwrap(CodexBundledSkill.visualProvider.bundledSource(bundle: Bundle(for: Self.self)))
        for file in ["SKILL.md", "templates/provider.toml", "templates/kinds/example.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path), file)
        }
        XCTAssertEqual(try CodexBundledSkill.visualProvider.install(from: folder, codexHome: home), .installed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("skills/flightdeck-visual-provider/templates/provider.toml").path))
    }

    func testTheProductionEntryPointInstallsEverySkillItIsGiven() async {
        await CodexBundledSkill.installOffMainActor(
            skills: [.delegate, .visualProvider], codexHome: home, bundle: Bundle(for: Self.self), debugBuild: false)
        for name in ["delegate", "visual-provider"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: home.appendingPathComponent("skills/flightdeck-\(name)/SKILL.md").path), name)
        }
    }

    // MARK: - Links, atomic refresh, junk

    private struct Injected: Error {}

    private func victim() throws -> URL {
        let url = root.appendingPathComponent("victim", isDirectory: true)
        try put("precious", at: url.appendingPathComponent("provider.toml"))
        try put("precious", at: url.appendingPathComponent("kinds/example.md"))
        return url
    }

    private func assertUntouched(_ victim: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try String(contentsOf: victim.appendingPathComponent("provider.toml"), encoding: .utf8),
                       "precious", file: file, line: line)
        XCTAssertEqual(try String(contentsOf: victim.appendingPathComponent("kinds/example.md"), encoding: .utf8),
                       "precious", file: file, line: line)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: victim.path).sorted(),
                       ["kinds", "kinds/example.md", "provider.toml"], file: file, line: line)
    }

    func testALinkPlantedInsideTheFolderIsAnEditAndNeverWrittenThrough() throws {
        _ = try skill.install(from: source, codexHome: home)
        let victim = try victim()
        try FileManager.default.removeItem(at: installed("templates"))
        try FileManager.default.createSymbolicLink(at: installed("templates"), withDestinationURL: victim)
        try put("skill v2", at: source.appendingPathComponent("SKILL.md"))
        try put("manifest v2", at: source.appendingPathComponent("templates/provider.toml"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .userEdited)
        XCTAssertFalse(try skill.uninstall(home: home))
        try assertUntouched(victim)
    }

    func testASymlinkedSkillFolderIsRefusedAndNothingIsWrittenThroughIt() throws {
        let victim = try victim()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("skills/flightdeck-demo"), withDestinationURL: victim)
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .unsafe)
        XCTAssertFalse(try skill.uninstall(home: home))
        try assertUntouched(victim)
    }

    func testARefreshInterruptedMidwayLeavesTheOldFolderAndHealsOnTheNextLaunch() throws {
        _ = try skill.install(from: source, codexHome: home)
        try put("skill v2", at: source.appendingPathComponent("SKILL.md"))
        try put("manifest v2", at: source.appendingPathComponent("templates/provider.toml"))
        XCTAssertThrowsError(try skill.install(entries: try CodexBundledSkill.entries(in: source), codexHome: home,
                                               stageFault: { count in if count == 1 { throw Injected() } }))
        XCTAssertEqual(try text("SKILL.md"), "skill v1")
        XCTAssertEqual(try text("templates/provider.toml"), "manifest v1")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("skills").path)
        XCTAssertEqual(siblings, ["flightdeck-demo"], "no staging folder is left behind")
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .refreshed)
        XCTAssertEqual(try text("templates/provider.toml"), "manifest v2")
    }

    func testAStagingFolderACrashLeftBehindIsRemovedOnTheNextInstall() throws {
        _ = try skill.install(from: source, codexHome: home)
        let stale = home.appendingPathComponent("skills/.flightdeck-demo.staging-dead")
        try put("old", at: stale.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    /// A crash right after the swap leaves the new files; the next launch must read them as ours.
    func testAFolderAlreadyHoldingTheNewFilesIsCurrentEvenWithAnOldSidecar() throws {
        _ = try skill.install(from: source, codexHome: home)
        let oldDigest = try String(contentsOf: installed(".flightdeck-managed"), encoding: .utf8)
        try put("skill v2", at: source.appendingPathComponent("SKILL.md"))
        _ = try skill.install(from: source, codexHome: home)
        try put(oldDigest, at: installed(".flightdeck-managed"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .current)
        XCTAssertNotEqual(try String(contentsOf: installed(".flightdeck-managed"), encoding: .utf8), oldDigest)
    }

    func testToolJunkIsNotAnEditButANestedSidecarNameIs() throws {
        _ = try skill.install(from: source, codexHome: home)
        try put("x", at: installed(".DS_Store"))
        try put("x", at: installed("__pycache__/a.pyc"))
        try put("x", at: installed(".git/HEAD"))
        try put("x", at: installed("SKILL.md.swp"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .current)
        try put("x", at: installed("templates/.flightdeck-managed"))
        XCTAssertEqual(try skill.install(from: source, codexHome: home), .userEdited)
    }

    /// The real `delegate` skill: an install made before folders existed recorded the plain
    /// SHA-256 of SKILL.md, and must still refresh and then read as current.
    func testAnInstalledDelegateSkillFromBeforeFoldersStillRefreshes() throws {
        let folder = try XCTUnwrap(CodexBundledSkill.delegate.bundledSource(bundle: Bundle(for: Self.self)))
        let bundled = try Data(contentsOf: folder.appendingPathComponent("SKILL.md"))
        let dir = home.appendingPathComponent("skills/flightdeck-delegate")
        try put("an older delegate", at: dir.appendingPathComponent("SKILL.md"))
        try put(CodexDelegateSkill.digest(Data("an older delegate".utf8)) + "\n", at: dir.appendingPathComponent(".flightdeck-managed"))
        XCTAssertEqual(try CodexBundledSkill.delegate.install(from: folder, codexHome: home), .refreshed)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("SKILL.md")), bundled)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(".flightdeck-managed"), encoding: .utf8),
                       CodexDelegateSkill.digest(bundled) + "\n")
        XCTAssertEqual(try CodexBundledSkill.delegate.install(from: folder, codexHome: home), .current)
    }
}
