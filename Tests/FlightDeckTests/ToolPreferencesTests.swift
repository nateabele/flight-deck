import XCTest
@testable import FlightDeck

@MainActor
final class ToolPreferencesTests: XCTestCase {
    /// Same in-memory stand-in `PreferencesStoreTests` uses, so no test touches the real
    /// defaults domain.
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    // MARK: DefaultTerminalResolver

    func testResolverPrefersTheFirstInstalledCandidate() {
        let command = DefaultTerminalResolver.command { $0 == "com.googlecode.iterm2" }
        XCTAssertEqual(command, "open -b com.googlecode.iterm2 ${cwd}")
    }

    func testResolverFallsBackToAppleTerminalWhenNothingIsFound() {
        // Terminal.app cannot be absent from macOS, so this is the honest floor rather than
        // an empty command the user would have to debug.
        XCTAssertEqual(
            DefaultTerminalResolver.command { _ in false },
            "open -b com.apple.Terminal ${cwd}"
        )
    }

    func testResolverRespectsCandidateOrderNotInstallOrder() {
        let command = DefaultTerminalResolver.command { $0 != "com.googlecode.iterm2" }
        XCTAssertEqual(command, "open -b com.mitchellh.ghostty ${cwd}")
    }

    // MARK: Migration

    func testAPreferencesBlobWithNoToolsKeyStillDecodes() throws {
        // The reason `storedTools` is Optional. `load()` decodes with `try?`, so a
        // non-optional field would fail every existing preferences.v1 blob and silently reset
        // the user's flags, overrides and shell settings.
        let legacy = #"{"globalFlags":{"values":{},"passthrough":[]},"projectFlags":{},"shell":{"environment":{},"clearChildSessionMarker":true}}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.storedTools)
    }

    func testMigrationMaterialisesEditorAndTerminal() {
        var prefs = Preferences()
        prefs.migrateToolsIfNeeded(terminalCommand: "open -b com.apple.Terminal ${cwd}")
        XCTAssertEqual(prefs.tools.map(\.name), ["Editor", "Terminal"])
        XCTAssertEqual(prefs.tools[0].command, "$EDITOR ${cwd}")
        XCTAssertEqual(prefs.tools[0].shortcut, ToolShortcut(key: "o", modifiers: [.command]))
        XCTAssertEqual(prefs.tools[1].command, "open -b com.apple.Terminal ${cwd}")
        XCTAssertEqual(prefs.tools[1].shortcut, ToolShortcut(key: "t", modifiers: [.command]))
    }

    func testMigrationIsIdempotentAndNeverOverwritesTheUsersList() {
        var prefs = Preferences()
        prefs.tools = [ToolDefinition(name: "Mine", symbol: "gear", command: "true")]
        prefs.migrateToolsIfNeeded(terminalCommand: "open -b com.apple.Terminal ${cwd}")
        XCTAssertEqual(prefs.tools.map(\.name), ["Mine"])
    }

    func testDeletingEveryToolStaysDeletedAcrossASaveAndLoad() {
        // The property a bare `?? defaults` getter would break: an empty list must persist as
        // empty, not resurrect Editor and Terminal on the next launch.
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.tools = []
        XCTAssertEqual(persistence.stored?.storedTools, [])

        let reopened = PreferencesStore(persistence: persistence)
        XCTAssertTrue(reopened.tools.isEmpty, "an emptied tool list must stay empty")
    }

    func testAFreshStoreMaterialisesTheDefaults() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertEqual(store.tools.map(\.name), ["Editor", "Terminal"])
    }

    func testToolsRoundTripThroughStorage() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.tools = [
            ToolDefinition(
                name: "Tower", symbol: "arrow.triangle.branch", command: "open -a Tower ${project}",
                shortcut: ToolShortcut(key: "g", modifiers: [.command, .shift]),
                showsInOverlay: false
            )
        ]
        let reopened = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reopened.tools.count, 1)
        XCTAssertEqual(reopened.tools[0].name, "Tower")
        XCTAssertEqual(reopened.tools[0].shortcut?.displayString, "⇧⌘G")
        XCTAssertFalse(reopened.tools[0].showsInOverlay)
    }
}
