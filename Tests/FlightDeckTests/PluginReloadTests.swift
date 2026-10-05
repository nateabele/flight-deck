import XCTest
@testable import FlightDeck

/// `PluginReload` picks the claude tabs that need `/reload-plugins`. Probe P1 showed that a
/// running session never notices a skill added to its plugin, so a wrong answer here either
/// leaves a tab without the skill until it is relaunched, or types into every tab on every launch.
final class PluginReloadTests: XCTestCase {
    private var plugin: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        plugin = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginReloadTests-\(UUID().uuidString)", isDirectory: true)
        try write("{}", to: ".claude-plugin/plugin.json")
        suite = "PluginReloadTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: plugin)
        defaults.removePersistentDomain(forName: suite)
    }

    private func write(_ text: String, to path: String) throws {
        let url = plugin.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Fingerprint

    func testFingerprintIsStableForUnchangedContent() throws {
        XCTAssertNotNil(PluginReload.fingerprint(of: plugin))
        XCTAssertEqual(PluginReload.fingerprint(of: plugin), PluginReload.fingerprint(of: plugin))
    }

    /// The P1 case exactly: a skill directory appears in a plugin that a session already loaded.
    func testFingerprintChangesWhenASkillIsAdded() throws {
        let before = PluginReload.fingerprint(of: plugin)
        try write("---\nname: delegate\n---\n", to: "skills/delegate/SKILL.md")
        XCTAssertNotEqual(PluginReload.fingerprint(of: plugin), before)
    }

    func testFingerprintChangesWhenBytesMoveBetweenFiles() throws {
        try write("ab", to: "a")
        try write("c", to: "b")
        let before = PluginReload.fingerprint(of: plugin)
        try write("a", to: "a")
        try write("bc", to: "b")
        XCTAssertNotEqual(PluginReload.fingerprint(of: plugin), before,
                          "unframed concatenation would hash both layouts to `abc`")
    }

    // MARK: - Changed since the last run

    func testFirstRunWithTheCheckCountsAsChanged() {
        XCTAssertTrue(PluginReload.pluginChanged(current: "v1", defaults: defaults),
                      "tabs adopted from a build that predates the check never had the skill")
    }

    func testSameFingerprintAsLastRunIsUnchanged() {
        _ = PluginReload.pluginChanged(current: "v1", defaults: defaults)
        XCTAssertFalse(PluginReload.pluginChanged(current: "v1", defaults: defaults))
    }

    func testNewFingerprintIsChangedOnceThenRecorded() {
        _ = PluginReload.pluginChanged(current: "v1", defaults: defaults)
        XCTAssertTrue(PluginReload.pluginChanged(current: "v2", defaults: defaults))
        XCTAssertFalse(PluginReload.pluginChanged(current: "v2", defaults: defaults))
    }

    func testUnreadablePluginNeverTriggersAReload() {
        XCTAssertFalse(PluginReload.pluginChanged(current: nil, defaults: defaults))
        XCTAssertNil(defaults.string(forKey: PluginReload.fingerprintDefaultsKey),
                     "a nil must not overwrite the record, or the next good run reloads everything")
    }

    // MARK: - Which tabs

    func testAdoptedTabsNeedAReloadOnlyWhenThePluginChanged() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(PluginReload(adopted: [a, b], pluginChanged: true).pending, [a, b])
        XCTAssertTrue(PluginReload(adopted: [a, b], pluginChanged: false).pending.isEmpty)
    }

    func testATabLeavesTheQueueOnceSentOrForgotten() {
        let a = UUID(), b = UUID()
        var reload = PluginReload(adopted: [a, b], pluginChanged: true)
        reload.sent(a)
        reload.forget(b)
        XCTAssertFalse(reload.needsReload(a))
        XCTAssertFalse(reload.needsReload(b))
    }

    func testCommandIsTheOneP1Verified() {
        XCTAssertEqual(PluginReload.command, "/reload-plugins")
    }
}
