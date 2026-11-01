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
}
