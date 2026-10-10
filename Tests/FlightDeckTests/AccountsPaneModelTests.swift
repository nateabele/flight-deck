import XCTest
import IntakeKit
@testable import FlightDeck

/// Settings → Accounts as rows (unify brief R7): grouping, what is hidden, and every drag.
final class AccountsPaneModelTests: XCTestCase {
    private func account(_ name: String, _ agent: AgentID = .claude, removed: Bool = false) -> AgentAccount {
        AgentAccount(agent: agent, displayName: name, home: URL(fileURLWithPath: "/tmp/fd-pane/\(name)"),
                     removedAt: removed ? Date() : nil)
    }

    private lazy var a = account("A")
    private lazy var b = account("B")
    private lazy var c = account("C")
    private lazy var d = account("D")
    private lazy var x = account("X", .codex)

    private func list() -> AccountList {
        AccountList(entries: [
            .account(a),
            .account(x),
            .pool(AccountPool(id: "team", label: "Team", agent: .claude, members: [b, c])),
            .account(d),
        ])
    }

    private func names(_ list: AccountList, _ agent: AgentID = .claude) -> [String] {
        AccountsPaneModel.groups(list).first { $0.agent == agent }!.rows.map(\.debugName)
    }

    // MARK: Grouping

    func testEveryKnownAgentGetsAGroupInAgentOrder() {
        XCTAssertEqual(AccountsPaneModel.groups(list()).map(\.agent), AgentID.allCases)
    }

    func testRowsNestPoolMembersUnderTheirPoolInListOrder() {
        XCTAssertEqual(names(list()), ["A", "pool Team", "  B", "  C", "D"])
        XCTAssertEqual(names(list(), .codex), ["X"])
    }

    func testACollapsedPoolHidesItsMembers() {
        let rows = AccountsPaneModel.groups(list(), collapsed: ["team"]).first!.rows.map(\.debugName)
        XCTAssertEqual(rows, ["A", "pool Team", "D"])
    }

    func testRemovedAccountsAndTheStoredDefaultPoolEntryAreNotRows() {
        var l = list()
        l.entries.append(.account(account("Gone", removed: true)))
        l.entries.append(.pool(AccountPool(id: CapacityPool.defaultID(for: .claude), label: "Claude default", agent: .claude)))
        XCTAssertEqual(names(l), ["A", "pool Team", "  B", "  C", "D"])
    }

    /// The account a project with no assignment uses: the first live one, pool members included.
    func testTheDefaultAccountIsTheFirstLiveAccount() {
        XCTAssertEqual(AccountsPaneModel.groups(list()).first!.defaultAccountID, a.id)
        var l = list()
        l.entries.removeFirst()
        XCTAssertEqual(AccountsPaneModel.groups(l).first!.defaultAccountID, b.id)
    }

    // MARK: Drag payloads

    func testPayloadsRoundTrip() {
        for id in [AccountEntry.ID.account(a.id), .pool("team")] {
            XCTAssertEqual(AccountsPaneModel.entryID(fromPayload: AccountsPaneModel.payload(id)), id)
        }
        XCTAssertNil(AccountsPaneModel.entryID(fromPayload: "nonsense"))
    }

    // MARK: Drops

    func testDroppingAnAccountOnAPoolAppendsItToThePool() throws {
        var l = list()
        try AccountsPaneModel.drop(.account(a.id), on: .intoPool("team", before: nil), in: &l)
        XCTAssertEqual(names(l), ["pool Team", "  B", "  C", "  A", "D"])
    }

    func testDroppingAnAccountOnAMemberInsertsItBeforeThatMember() throws {
        var l = list()
        try AccountsPaneModel.drop(.account(d.id), on: .intoPool("team", before: c.id), in: &l)
        XCTAssertEqual(names(l), ["A", "pool Team", "  B", "  D", "  C"])
    }

    func testReorderingInsideAPoolChangesLeaseOrder() throws {
        var l = list()
        try AccountsPaneModel.drop(.account(c.id), on: .intoPool("team", before: b.id), in: &l)
        XCTAssertEqual(l.pool("team")?.members.map(\.displayName), ["C", "B"])
    }

    func testDroppingAMemberOnATopLevelRowTakesItOutOfThePool() throws {
        var l = list()
        try AccountsPaneModel.drop(.account(c.id), on: .before(.account(a.id)), in: &l)
        XCTAssertEqual(names(l), ["C", "A", "pool Team", "  B", "D"])
    }

    func testDroppingOnTheGroupEndPutsItLastAtTopLevel() throws {
        var l = list()
        try AccountsPaneModel.drop(.account(b.id), on: .endOfGroup(.claude), in: &l)
        XCTAssertEqual(names(l), ["A", "pool Team", "  C", "D", "B"])
    }

    func testAPoolReordersAtTopLevelAndNeverNests() throws {
        var l = list()
        try AccountsPaneModel.drop(.pool("team"), on: .before(.account(a.id)), in: &l)
        XCTAssertEqual(names(l), ["pool Team", "  B", "  C", "A", "D"])
        try l.addPool(AccountPool(id: "other", label: "Other", agent: .claude))
        try AccountsPaneModel.drop(.pool("other"), on: .intoPool("team", before: b.id), in: &l)
        XCTAssertEqual(names(l), ["pool Other", "pool Team", "  B", "  C", "A", "D"],
                       "a pool dropped into a pool lands before it instead")
    }

    func testDroppingOntoItselfChangesNothing() throws {
        var l = list()
        try AccountsPaneModel.drop(.account(a.id), on: .before(.account(a.id)), in: &l)
        XCTAssertEqual(l, list())
    }

    func testACrossAgentDropIsRefused() {
        var l = list()
        XCTAssertThrowsError(try AccountsPaneModel.drop(.account(x.id), on: .intoPool("team", before: nil), in: &l)) {
            XCTAssertEqual($0 as? AccountListError, .agentMismatch(account: .codex, pool: .claude))
        }
        XCTAssertThrowsError(try AccountsPaneModel.drop(.account(x.id), on: .before(.account(a.id)), in: &l))
        XCTAssertEqual(l, list())
    }

    // MARK: Copy

    func testThePoolSummarySaysMembersAndThresholds() {
        let pool = list().pool("team")!
        XCTAssertEqual(AccountsPaneModel.summary(of: pool), "2 accounts · new work stops at 80%, hands off at 95%")
        let local = AccountPool(id: "l", label: "L", agent: .claude, kind: .local, endpoint: "http://h", concurrencyCap: 3)
        XCTAssertEqual(AccountsPaneModel.summary(of: local), "Local · http://h · up to 3 at once")
    }

    func testIdentityCaption() {
        var acct = a
        XCTAssertEqual(AccountsPaneModel.identityCaption(acct), "Not signed in")
        acct.cachedIdentity = AccountIdentity(email: "e@example.com", organization: "Org")
        XCTAssertEqual(AccountsPaneModel.identityCaption(acct), "e@example.com · Org")
    }
}
