import XCTest
@testable import FlightDeck

final class AgentAccountTests: XCTestCase {
    func testBuiltInHomes() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        XCTAssertEqual(AgentID.claude.builtInHome, home.appendingPathComponent(".claude", isDirectory: true))
        XCTAssertEqual(AgentID.codex.builtInHome, home.appendingPathComponent(".codex", isDirectory: true))
    }

    /// The whole point of `isBuiltIn` being computed: it must not depend on a stored flag that
    /// a relocate could leave stale.
    func testIsBuiltInComparesTheHomeNotAStoredFlag() {
        let builtIn = AgentAccount(agent: .claude, displayName: "Default", home: AgentID.claude.builtInHome)
        let other = AgentAccount(
            agent: .claude, displayName: "Work",
            home: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-work")
        )
        XCTAssertTrue(builtIn.isBuiltIn)
        XCTAssertFalse(other.isBuiltIn)
    }

    /// Trailing-slash and `..` differences must not make one home look like two — the
    /// duplicate-home rule in Task 5 leans on this.
    func testIsBuiltInIgnoresPathSpelling() {
        let spelled = URL(fileURLWithPath: NSHomeDirectory() + "/./.claude/", isDirectory: true)
        XCTAssertTrue(AgentAccount(agent: .claude, displayName: "D", home: spelled).isBuiltIn)
    }

    func testRoundTripsThroughJSON() throws {
        let account = AgentAccount(
            agent: .codex, displayName: "Work", home: AgentID.codex.builtInHome,
            cachedIdentity: AccountIdentity(email: "a@b.c", organization: "Org", readAt: Date(timeIntervalSince1970: 1))
        )
        let data = try JSONEncoder().encode(account)
        XCTAssertEqual(try JSONDecoder().decode(AgentAccount.self, from: data), account)
    }
}
