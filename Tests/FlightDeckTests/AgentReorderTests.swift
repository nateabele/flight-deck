import XCTest
@testable import FlightDeck

final class AgentReorderTests: XCTestCase {
    func testMovingAnAgentReordersTheList() {
        var prefs = Preferences()
        prefs.agents = Preferences.defaultAgents          // claude, codex

        prefs.moveAgents(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(prefs.agents.map(\.id), [.codex, .claude])
    }

    func testReorderingChangesWhichAgentOwnsCommandN() {
        var prefs = Preferences()
        prefs.agents = Preferences.defaultAgents
        prefs.moveAgents(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(NewSessionAffordance.slots(for: prefs.agents).first?.agent, .codex,
                       "the list is the shortcut binding; moving a row must rebind ⌘N")
    }

    func testAgentOptionsSurviveAReorder() {
        var prefs = Preferences()
        var flags = FlagSet()
        flags.values["--model"] = .value("opus")
        prefs.agents = [AgentSettings(id: .claude, options: .claude(flags)),
                        AgentSettings(id: .codex, options: .codex(CodexThreadOptions()))]

        prefs.moveAgents(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        guard case .claude(let moved)? = prefs.agents.last?.options else {
            return XCTFail("claude's options must travel with its row")
        }
        XCTAssertEqual(moved.values["--model"], .value("opus"))
    }
}
