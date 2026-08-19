import XCTest
@testable import FlightDeck

final class AgentSettingsTests: XCTestCase {
    func testPreferencesWithNoAgentListDefaultToClaudeThenCodex() {
        // Position is meaning: index 0 is ⌘N. An upgrade must leave ⌘N on claude, which is
        // what every existing user's muscle memory expects.
        let prefs = Preferences()
        XCTAssertEqual(prefs.agents.map(\.id), [.claude, .codex])
    }

    func testExistingGlobalFlagsMigrateIntoTheClaudeEntry() {
        var prefs = Preferences()
        var flags = FlagSet()
        flags.values["--model"] = .value("opus")
        prefs.globalFlags = flags

        prefs.migrateAgentsIfNeeded()

        guard case .claude(let migrated)? = prefs.agents.first(where: { $0.id == .claude })?.options
        else { return XCTFail("claude's options must be a FlagSet") }
        XCTAssertEqual(migrated.values["--model"], .value("opus"),
                       "an upgrade must not silently drop the user's flags")
    }

    func testOrderRoundTripsThroughCoding() throws {
        var prefs = Preferences()
        prefs.agents = [AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
                        AgentSettings(id: .claude, options: .claude(FlagSet()))]

        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))

        XCTAssertEqual(back.agents.map(\.id), [.codex, .claude], "reordering must persist")
    }
}
