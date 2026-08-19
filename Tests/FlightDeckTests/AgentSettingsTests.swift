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

    /// The discriminator, not key presence, must decide which branch decodes. A JSON blob
    /// tagged `"agent":"claude"` but carrying only a `"codex"` payload (no `"flags"` key) must
    /// throw rather than silently succeed by falling through to whichever key happens to be
    /// present — a silent mis-decode there would hand claude's tab codex's options, or vice
    /// versa. Covers `AgentOptions.init(from:)` in `AgentSettings.swift`.
    func testAClaudeTaggedPayloadCannotDecodeFromACodexOnlyBody() {
        let json = """
        {"id":"claude","options":{"agent":"claude","codex":{"addDirs":[]}}}
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        ) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("expected a missing-key decode failure, got \(error)")
            }
        }
    }

    /// The mirror image: a `"codex"`-tagged blob carrying only a `"flags"` payload must also
    /// throw, not silently decode as claude's options.
    func testACodexTaggedPayloadCannotDecodeFromAClaudeOnlyBody() {
        let json = """
        {"id":"codex","options":{"agent":"codex","flags":{"values":{},"passthrough":[]}}}
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        ) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("expected a missing-key decode failure, got \(error)")
            }
        }
    }
}
