import XCTest
@testable import FlightDeck

@MainActor
final class PreferencesStoreTests: XCTestCase {
    /// In-memory stand-in so tests never touch the real defaults domain.
    final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        var saveCount = 0
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences; saveCount += 1 }
    }

    func testStartsFromDefaultsWhenNothingIsStored() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertTrue(store.preferences.globalFlags.isEmpty)
        XCTAssertNil(store.preferences.shell.shellOverride)
        XCTAssertTrue(store.preferences.shell.clearChildSessionMarker)
    }

    func testLoadsStoredPreferences() {
        let persistence = MemoryPersistence()
        persistence.stored = Preferences(globalFlags: FlagSet(values: ["--model": .value("opus")]))
        let store = PreferencesStore(persistence: persistence)
        XCTAssertEqual(store.preferences.globalFlags.values["--model"], .value("opus"))
    }

    /// Migration has to reach disk inside `init`, and this is the test that proves it: Swift
    /// does not fire the `preferences` `didSet` on an initializing assignment, so the only
    /// other write path is the user happening to edit a preference. Without the write, every
    /// launch re-mints the seeded accounts with fresh `UUID()`s — a `Session.accountID` stamped
    /// on launch 1 dangles on launch 2, and the tab restores orphaned under an "account no
    /// longer exists" alert it can never recover from.
    func testMigratedAccountIDsSurviveASecondStoreOverTheSamePersistence() {
        let persistence = MemoryPersistence()
        let ids = PreferencesStore(persistence: persistence).preferences.accounts.map(\.id)
        XCTAssertFalse(ids.isEmpty, "migration seeds a built-in account per agent")

        let relaunched = PreferencesStore(persistence: persistence)
        XCTAssertEqual(relaunched.preferences.accounts.map(\.id), ids,
                       "the migrated blob must be on disk, not re-derived per launch")
    }

    /// The other half of the guard: a launch that migrates nothing writes nothing, so a
    /// steady-state start does not touch the defaults key at all.
    func testALaunchWithNothingToMigrateDoesNotRewriteTheBlob() {
        let persistence = MemoryPersistence()
        _ = PreferencesStore(persistence: persistence)
        let settled = persistence.saveCount
        XCTAssertGreaterThan(settled, 0, "the first launch has migrations to persist")

        _ = PreferencesStore(persistence: persistence)
        XCTAssertEqual(persistence.saveCount, settled)
    }

    /// A nil persistence stays hermetic — the `-FlightDeckResetState` gate and every test that
    /// passes nil must not acquire a write path by way of migration.
    func testANilPersistenceStillMigratesInMemoryAndWritesNowhere() {
        let store = PreferencesStore(persistence: nil)
        XCTAssertFalse(store.preferences.accounts.isEmpty)
    }

    func testMutationPersists() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.preferences.globalFlags.values["--verbose"] = .on
        XCTAssertEqual(persistence.stored?.globalFlags.values["--verbose"], .on)
    }

    func testResolvedOptionsMergeProjectOverGlobalPerFlag() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.agents = [
            AgentSettings(
                id: .claude,
                options: .claude(FlagSet(values: ["--model": .value("opus"), "--effort": .value("high")]))
            )
        ]
        store.setProjectSettings(
            "/tmp/repo",
            ProjectSettings(options: [.claude: .claude(FlagSet(values: ["--model": .value("sonnet")]))])
        )
        guard case .claude(let resolved) = store.resolvedOptions(for: .claude, project: "/tmp/repo") else {
            return XCTFail("expected claude options")
        }
        XCTAssertEqual(resolved.values["--model"], .value("sonnet"))
        XCTAssertEqual(resolved.values["--effort"], .value("high"))
    }

    func testProjectWithoutOverrideResolvesToGlobalAgentOptions() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        let globalFlags = FlagSet(values: ["--model": .value("opus")])
        store.preferences.agents = [AgentSettings(id: .claude, options: .claude(globalFlags))]
        guard case .claude(let resolved) = store.resolvedOptions(for: .claude, project: "/tmp/other") else {
            return XCTFail("expected claude options")
        }
        XCTAssertEqual(resolved, globalFlags)
    }

    func testPathsAreStandardizedSoEquivalentPathsShareAnOverride() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.setProjectSettings(
            "/tmp/repo/",
            ProjectSettings(options: [.claude: .claude(FlagSet(values: ["--verbose": .on]))])
        )
        guard case .claude(let flags)? = store.projectSettings("/tmp/repo").options[.claude] else {
            return XCTFail("expected claude options")
        }
        XCTAssertEqual(flags.values["--verbose"], .on)
    }

    func testClearingProjectOptionsFallsBackToGlobals() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.agents = [
            AgentSettings(id: .claude, options: .claude(FlagSet(values: ["--model": .value("opus")])))
        ]
        store.setProjectSettings(
            "/tmp/repo",
            ProjectSettings(options: [.claude: .claude(FlagSet(values: ["--model": .value("sonnet")]))])
        )
        store.setProjectSettings("/tmp/repo", ProjectSettings())
        guard case .claude(let resolved) = store.resolvedOptions(for: .claude, project: "/tmp/repo") else {
            return XCTFail("expected claude options")
        }
        XCTAssertEqual(resolved.values["--model"], .value("opus"))
        XCTAssertTrue(store.configuredProjectPaths.isEmpty)
    }

    /// A project's settings outlive the project itself — closing a project removes it from
    /// `SessionStore` entirely — so a configured path must be enumerable independently of which
    /// projects happen to be open.
    func testConfiguredProjectPathsSurviveIndependentlyOfOpenProjects() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.setProjectSettings(
            "/tmp/repo",
            ProjectSettings(options: [.claude: .claude(FlagSet(values: ["--verbose": .on]))])
        )
        let reloaded = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reloaded.configuredProjectPaths, ["/tmp/repo"])
    }

    func testConfiguredProjectPathsAreSorted() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.setProjectSettings("/tmp/b", ProjectSettings(options: [.claude: .claude(FlagSet(values: ["--verbose": .on]))]))
        store.setProjectSettings("/tmp/a", ProjectSettings(options: [.claude: .claude(FlagSet(values: ["--verbose": .on]))]))
        XCTAssertEqual(store.configuredProjectPaths, ["/tmp/a", "/tmp/b"])
    }

    func testCodableRoundTrip() throws {
        var preferences = Preferences()
        preferences.globalFlags = FlagSet(values: ["--add-dir": .list(["a"])], passthrough: ["--x"])
        preferences.projectFlags = ["/tmp/repo": FlagSet(values: ["--verbose": .on])]
        preferences.shell = ShellPreferences(
            shellOverride: "/bin/fish", environment: ["A": "B"], clearChildSessionMarker: false
        )
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), preferences)
    }

    // MARK: shell

    func testResolvedShellPrefersTheOverride() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.shell.shellOverride = "/bin/fish"
        XCTAssertEqual(store.resolvedShell(environment: ["SHELL": "/bin/bash"]), "/bin/fish")
    }

    func testResolvedShellFallsBackToShellResolver() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertEqual(store.resolvedShell(environment: ["SHELL": "/bin/bash"]), "/bin/bash")
    }

    func testSessionEnvironmentIncludesCustomVariables() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.shell.environment = ["FOO": "bar"]
        XCTAssertEqual(store.sessionEnvironment(inherited: [:])["FOO"], "bar")
    }

    /// The FOLLOWUPS.md footgun: an inherited marker turns transcript saving off, which
    /// silently kills inbound rename sync.
    func testClearsChildSessionMarkerWhenInheritedAndEnabled() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        let environment = store.sessionEnvironment(inherited: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        XCTAssertEqual(environment["CLAUDE_CODE_CHILD_SESSION"], "")
    }

    func testDoesNotClearChildSessionMarkerWhenDisabled() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.shell.clearChildSessionMarker = false
        let environment = store.sessionEnvironment(inherited: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        XCTAssertNil(environment["CLAUDE_CODE_CHILD_SESSION"])
    }

    func testDoesNotAddTheMarkerWhenItWasNotInherited() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertNil(store.sessionEnvironment(inherited: [:])["CLAUDE_CODE_CHILD_SESSION"])
    }

    // MARK: Auto-resume

    func testAutoResumeDefaultsOff() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertFalse(store.autoResumesRunningSessions)
        XCTAssertNil(store.preferences.claude)
    }

    func testEnablingAutoResumePersists() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.autoResumesRunningSessions = true
        XCTAssertEqual(persistence.stored?.claude?.autoResumeRunningSessions, true)
        XCTAssertTrue(store.autoResumesRunningSessions)
    }

    func testDisablingAutoResumeRoundTrips() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.autoResumesRunningSessions = true
        store.autoResumesRunningSessions = false
        XCTAssertFalse(store.autoResumesRunningSessions)
    }

    /// The load-bearing one. A `preferences.v1` blob written before this field existed must
    /// still decode — `load()` uses `try?`, so a throw here resets every flag, project
    /// override and shell setting the user has. Same trap as `Preferences.confirmations`.
    ///
    /// Built by encoding a real `Preferences` and deleting the key, rather than by hand, so
    /// the fixture cannot drift from whatever `FlagSet` actually encodes to.
    func testPreferencesWithoutTheClaudeKeyStillDecode() throws {
        let original = Preferences(
            globalFlags: FlagSet(values: ["--model": .value("opus")]),
            claude: ClaudePreferences(autoResumeRunningSessions: true)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(original))
                as? [String: Any]
        )
        object.removeValue(forKey: "claude")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)

        XCTAssertNil(decoded.claude)
        XCTAssertEqual(decoded.globalFlags.values["--model"], .value("opus"))
        XCTAssertTrue(decoded.shell.clearChildSessionMarker)
    }

    /// Same trap, for `terminalFontSize`: a `preferences.v1` blob written before this task
    /// must still decode, with every other field intact.
    func testPreferencesWithoutTheTerminalFontSizeKeyStillDecode() throws {
        let original = Preferences(
            globalFlags: FlagSet(values: ["--model": .value("opus")]),
            claude: ClaudePreferences(autoResumeRunningSessions: true)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(original))
                as? [String: Any]
        )
        object.removeValue(forKey: "terminalFontSize")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)

        XCTAssertNil(decoded.terminalFontSize)
        XCTAssertEqual(decoded.globalFlags.values["--model"], .value("opus"))
        XCTAssertEqual(decoded.claude?.autoResumeRunningSessions, true)
        XCTAssertTrue(decoded.shell.clearChildSessionMarker)
    }
}
