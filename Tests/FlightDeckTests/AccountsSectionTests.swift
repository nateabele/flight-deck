import XCTest
@testable import FlightDeck

@MainActor
final class AccountsSectionTests: XCTestCase {
    func testDefaultHomeIsDerivedFromTheNameAndAgent() {
        let home = AccountDraft.defaultHome(for: .claude, name: "Field Wealth")
        XCTAssertEqual(home.lastPathComponent, ".claude-field-wealth")
        XCTAssertEqual(AccountDraft.defaultHome(for: .codex, name: "Work").lastPathComponent, ".codex-work")
    }

    func testTheBuiltInAccountCannotBeRemoved() {
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        XCTAssertFalse(AccountsSection.canRemove(builtIn, boundAccountIDs: []))
    }

    func testAnAccountWithLiveSessionsCannotBeRemovedOrRelocated() {
        let work = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        XCTAssertFalse(AccountsSection.canRemove(work, boundAccountIDs: [work.id]))
        XCTAssertTrue(AccountsSection.canRemove(work, boundAccountIDs: []))
    }

    /// Two accounts on one home would put two `CodexStack`s on one `session_index.jsonl`, so the
    /// sheet refuses before anything is created rather than failing later at launch.
    func testTheAddSheetRefusesAHomeAnotherAccountAlreadyUses() {
        let store = PreferencesStore(persistence: nil)
        let taken = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        store.preferences.storedAccounts = [taken]
        XCTAssertEqual(
            AccountDraft.validate(home: URL(fileURLWithPath: "/tmp/w"), editing: nil, in: store),
            .homeAlreadyUsed
        )
        XCTAssertEqual(
            AccountDraft.validate(home: URL(fileURLWithPath: "/tmp/other"), editing: nil, in: store),
            .ok
        )
    }
}
