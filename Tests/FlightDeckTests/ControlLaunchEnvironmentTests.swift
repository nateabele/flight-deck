import XCTest
@testable import FlightDeck

@MainActor
final class ControlLaunchEnvironmentTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    /// A store with a live `PreferencesStore`, built the way `FleetTestHarness` builds one's
    /// preferences: `SessionStore.preferences` is a `let` handed in at init, so a bare store has
    /// no Shell pane at all and the override below would silently test nothing.
    private func makeStore() -> SessionStore {
        SessionStore(
            provider: nil, persistence: nil,
            preferences: PreferencesStore(persistence: MemoryPersistence())
        )
    }

    func testALaunchedTabCarriesItsControlIdentityAndTheShellPaneCannotOverrideIt() {
        let store = makeStore()
        let secret = Data(repeating: 3, count: 32)
        store.controlSocket = URL(fileURLWithPath: "/s/control.sock")
        store.controlSecret = secret
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        // A hand-typed value in the Shell pane must not repoint a tab at another app instance.
        store.preferences?.preferences.shell.environment["FLIGHT_DECK_CONTROL_SOCKET"] = "/elsewhere"
        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)
        XCTAssertEqual(env["FLIGHT_DECK_SESSION_ID"], session.id.uuidString)
        XCTAssertEqual(env["FLIGHT_DECK_CONTROL_SOCKET"], "/s/control.sock")
        XCTAssertEqual(ControlEnvironment.session(forToken: env["FLIGHT_DECK_CALLER"] ?? "", secret: secret),
                       session.id)
    }

    func testNoControlVariablesWhenTheSocketIsOff() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)
        XCTAssertNil(env["FLIGHT_DECK_CONTROL_SOCKET"])
    }

    /// The status-line wrapper draws the user's own status line from this variable; without it
    /// every claude tab's status line goes blank. A project's settings outrank the account's, so
    /// this pins the variable without depending on the developer's own ~/.claude.
    func testAClaudeTabCarriesTheUsersStatusLineCommand() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("fd-sl-\(UUID().uuidString)")
        let settings = project.appendingPathComponent(".claude/settings.local.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try Data(#"{"statusLine":{"type":"command","command":"printf project-line"}}"#.utf8).write(to: settings)
        let store = makeStore()
        let session = store.newSession(in: project)
        // A value typed into the Shell pane must not outlive the user's real settings.
        store.preferences?.preferences.shell.environment[ClaudeStatusLine.userCommandVariable] = "stale"
        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)
        XCTAssertEqual(env[ClaudeStatusLine.userCommandVariable], "printf project-line")
    }
}
