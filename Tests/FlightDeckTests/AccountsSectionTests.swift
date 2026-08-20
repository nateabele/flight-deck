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

    /// `deleteFiles` never touches a real directory in this suite — a spy stands in for the
    /// Trash so the run leaves no junk behind, and it hermetically proves the call site is the
    /// account's own `home` and nothing else.
    func testDeleteFilesTrashesTheAccountsOwnHomeForAnOrdinaryAccount() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        store.preferences.storedAccounts = [work]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: work.id, boundAccountIDs: [], in: store) {
            trashed.append($0)
        }

        XCTAssertTrue(ok)
        XCTAssertEqual(trashed, [work.home])
    }

    /// The built-in home must never reach the trash closure, no matter what disables the menu
    /// item — `deleteFiles` re-checks this itself immediately before the call.
    func testDeleteFilesRefusesTheBuiltInAccount() {
        let store = PreferencesStore(persistence: nil)
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        store.preferences.storedAccounts = [builtIn]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: builtIn.id, boundAccountIDs: [], in: store) {
            trashed.append($0)
        }

        XCTAssertFalse(ok)
        XCTAssertTrue(trashed.isEmpty)
    }

    /// Same guard, the other reason: an account with a tab open on it right now must not have
    /// its home pulled out from under that tab.
    func testDeleteFilesRefusesAnAccountWithLiveSessions() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        store.preferences.storedAccounts = [work]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: work.id, boundAccountIDs: [work.id], in: store) {
            trashed.append($0)
        }

        XCTAssertFalse(ok)
        XCTAssertTrue(trashed.isEmpty)
    }
}
