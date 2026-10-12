import XCTest
import IntakeKit
@testable import FlightDeck

/// `refreshAccountIdentities` is what turns a finished sign-in into "email · org" under the
/// row. Before it existed the label was read only when an account was seeded or relocated, so
/// an account added before its first login said "Not signed in" forever — the login had
/// written `<home>/.claude.json`, and nothing ever read it again.
@MainActor
final class AccountIdentityRefreshTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writeClaudeLogin(at home: URL, email: String, organization: String) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let json = #"{"oauthAccount":{"emailAddress":"\#(email)","organizationName":"\#(organization)"}}"#
        try Data(json.utf8).write(to: home.appendingPathComponent(".claude.json"))
    }

    /// The reported case: a pool member added before its first login, then signed in.
    func testAPoolMemberSignedInAfterItWasAddedPicksUpItsIdentity() throws {
        let home = root.appendingPathComponent("claude-field-team", isDirectory: true)
        let member = AgentAccount(agent: .claude, displayName: "Field Team", home: home)
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [
            .pool(AccountPool(id: PoolID("pool-field"), label: "Field", agent: .claude, members: [member]))
        ])
        XCTAssertNil(store.account(id: member.id)?.cachedIdentity)

        try writeClaudeLogin(at: home, email: "e@example.com", organization: "field")
        store.refreshAccountIdentities()

        let identity = try XCTUnwrap(store.account(id: member.id)?.cachedIdentity)
        XCTAssertEqual(identity.email, "e@example.com")
        XCTAssertEqual(identity.organization, "field")
    }

    /// A login switched to another org shows the new one, not the one read at seed time.
    func testAStaleIdentityIsReplaced() throws {
        let home = root.appendingPathComponent("work", isDirectory: true)
        let account = AgentAccount(
            agent: .claude, displayName: "Work", home: home,
            cachedIdentity: AccountIdentity(email: "e@example.com", organization: "Old Org")
        )
        let store = PreferencesStore(persistence: nil)
        store.preferences.accounts = [account]

        try writeClaudeLogin(at: home, email: "e@example.com", organization: "New Org")
        store.refreshAccountIdentities()

        XCTAssertEqual(store.account(id: account.id)?.cachedIdentity?.organization, "New Org")
    }

    /// The pane calls this on a timer, and every preferences write is persisted: an unchanged
    /// identity must not be rewritten just because its `readAt` moved.
    func testAnUnchangedIdentityIsNotRewritten() throws {
        let home = root.appendingPathComponent("work", isDirectory: true)
        try writeClaudeLogin(at: home, email: "e@example.com", organization: "Org")
        let read = AccountIdentity(email: "e@example.com", organization: "Org", readAt: Date(timeIntervalSince1970: 0))
        let account = AgentAccount(agent: .claude, displayName: "Work", home: home, cachedIdentity: read)
        let store = PreferencesStore(persistence: nil)
        store.preferences.accounts = [account]
        let before = store.preferences

        store.refreshAccountIdentities()

        XCTAssertEqual(store.preferences, before)
    }

    /// A signed-out home clears the label rather than keeping the old login's email.
    func testASignedOutHomeClearsTheIdentity() throws {
        let home = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        let account = AgentAccount(
            agent: .claude, displayName: "Work", home: home,
            cachedIdentity: AccountIdentity(email: "e@example.com", organization: "Org")
        )
        let store = PreferencesStore(persistence: nil)
        store.preferences.accounts = [account]

        store.refreshAccountIdentities()

        XCTAssertNil(store.account(id: account.id)?.cachedIdentity)
    }
}
