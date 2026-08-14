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

    func testMutationPersists() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.preferences.globalFlags.values["--verbose"] = .on
        XCTAssertEqual(persistence.stored?.globalFlags.values["--verbose"], .on)
    }

    func testResolvedFlagsMergeProjectOverProject() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.globalFlags = FlagSet(values: ["--model": .value("opus"), "--effort": .value("high")])
        store.setProjectOverride("/tmp/repo", FlagSet(values: ["--model": .value("sonnet")]))
        let resolved = store.resolvedFlags(forProject: "/tmp/repo")
        XCTAssertEqual(resolved.values["--model"], .value("sonnet"))
        XCTAssertEqual(resolved.values["--effort"], .value("high"))
    }

    func testProjectWithoutOverrideResolvesToGlobals() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.globalFlags = FlagSet(values: ["--model": .value("opus")])
        XCTAssertEqual(store.resolvedFlags(forProject: "/tmp/other"), store.preferences.globalFlags)
    }

    func testPathsAreStandardizedSoEquivalentPathsShareAnOverride() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.setProjectOverride("/tmp/repo/", FlagSet(values: ["--verbose": .on]))
        XCTAssertEqual(store.resolvedFlags(forProject: "/tmp/repo").values["--verbose"], .on)
    }

    func testRemoveProjectOverrideFallsBackToGlobals() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.globalFlags = FlagSet(values: ["--model": .value("opus")])
        store.setProjectOverride("/tmp/repo", FlagSet(values: ["--model": .value("sonnet")]))
        store.removeProjectOverride("/tmp/repo")
        XCTAssertEqual(store.resolvedFlags(forProject: "/tmp/repo").values["--model"], .value("opus"))
        XCTAssertTrue(store.overriddenProjectPaths.isEmpty)
    }

    /// An override outlives the project it belongs to — closing a project removes it from
    /// `SessionStore` entirely — so the override must be enumerable independently of which
    /// projects happen to be open.
    func testOverridePathsSurviveIndependentlyOfOpenProjects() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.setProjectOverride("/tmp/repo", FlagSet(values: ["--verbose": .on]))
        let reloaded = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reloaded.overriddenProjectPaths, ["/tmp/repo"])
    }

    func testOverriddenPathsAreSorted() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.setProjectOverride("/tmp/b", FlagSet(values: ["--verbose": .on]))
        store.setProjectOverride("/tmp/a", FlagSet(values: ["--verbose": .on]))
        XCTAssertEqual(store.overriddenProjectPaths, ["/tmp/a", "/tmp/b"])
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
}
