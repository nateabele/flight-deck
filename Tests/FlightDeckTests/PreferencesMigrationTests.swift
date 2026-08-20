import XCTest
@testable import FlightDeck

final class PreferencesMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in [".claude-work", ".codex-work"] {
            let home = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let marker = name.hasPrefix(".claude") ? ".claude.json" : "auth.json"
            try "{}".write(to: home.appendingPathComponent(marker), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSeedsABuiltInAccountPerAgentAndDiscoversSiblings() {
        var prefs = Preferences()
        prefs.migrateAccountsIfNeeded(homeRoot: root)

        let claude = prefs.accounts(for: .claude)
        XCTAssertEqual(claude.count, 2)
        XCTAssertEqual(claude[0].home.lastPathComponent, ".claude", "the built-in home is seeded first and is the default")
        XCTAssertEqual(claude[1].home.lastPathComponent, ".claude-work")
        XCTAssertEqual(prefs.accounts(for: .codex).count, 2)
    }

    /// Idempotence is what makes it safe on every load. A re-scan would resurrect an account
    /// the user removed.
    func testMigrationDoesNotRescanOnceAccountsExist() {
        var prefs = Preferences()
        prefs.migrateAccountsIfNeeded(homeRoot: root)
        prefs.storedAccounts?.removeAll { $0.home.lastPathComponent.contains("-") }
        prefs.migrateAccountsIfNeeded(homeRoot: root)
        XCTAssertEqual(prefs.accounts(for: .claude).count, 1)
    }

    func testProjectFlagsBecomeUnspecifiedProjectSettingsWithFlagsIntact() {
        let flags = FlagSet(values: ["--model": .value("opus")])
        var prefs = Preferences(projectFlags: ["/p": flags])
        prefs.migrateProjectSettingsIfNeeded()

        let settings = prefs.projectSettings["/p"]
        XCTAssertNil(settings?.defaultAgent)
        XCTAssertTrue(settings?.accounts.isEmpty ?? false)
        XCTAssertEqual(settings?.options[.claude], .claude(flags))
    }

    func testGlobalFlagsFoldIntoTheClaudeAgentRow() {
        let flags = FlagSet(values: ["--verbose": .on])
        var prefs = Preferences(globalFlags: flags)
        prefs.migrateAgentsIfNeeded()
        prefs.migrateGlobalFlagsIfNeeded()
        XCTAssertEqual(prefs.agents.first { $0.id == .claude }?.options, .claude(flags))
    }

    /// The load-bearing guarantee: a blob written before any of this decodes rather than
    /// throwing, which is what stops a silent reset of every setting the user has.
    func testAPreAccountsBlobStillDecodes() throws {
        let legacy = Data(#"{"globalFlags":{"values":{},"passthrough":[]},"projectFlags":{},"shell":{"environment":{},"clearChildSessionMarker":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertNil(decoded.storedAccounts)
        XCTAssertTrue(decoded.projectSettings.isEmpty)
    }

    func testReorderingAccountsChangesTheDefaultForOneAgentOnly() {
        var prefs = Preferences()
        prefs.migrateAccountsIfNeeded(homeRoot: root)
        let codexBefore = prefs.accounts(for: .codex).map(\.id)
        prefs.moveAccounts(forAgent: .claude, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(prefs.accounts(for: .claude)[0].home.lastPathComponent, ".claude-work")
        XCTAssertEqual(prefs.accounts(for: .codex).map(\.id), codexBefore)
    }
}
