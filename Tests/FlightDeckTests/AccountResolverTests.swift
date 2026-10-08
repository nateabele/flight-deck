import XCTest
import IntakeKit
@testable import FlightDeck

/// `AccountResolver`: which login a project's work for one agent runs as, and the pool lease
/// that pays for it (unify brief R8). Tabs and planning runs both resolve through it.
@MainActor
final class AccountResolverTests: XCTestCase {
    private let project = "/tmp/fd-resolver-project"
    private var store: PreferencesStore!
    private var ledger: CapacityLedger!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var a: AgentAccount!
    private var b: AgentAccount!
    private var c: AgentAccount!
    private let poolID: PoolID = "claude-team"

    override func setUp() async throws {
        store = PreferencesStore(persistence: nil)
        let fixed = now
        ledger = CapacityLedger(now: { fixed })
        let root = URL(fileURLWithPath: "/tmp/fd-resolver", isDirectory: true)
        a = AgentAccount(agent: .claude, displayName: "A", home: root.appendingPathComponent("a"))
        b = AgentAccount(agent: .claude, displayName: "B", home: root.appendingPathComponent("b"))
        c = AgentAccount(agent: .claude, displayName: "C", home: root.appendingPathComponent("c"))
        store.preferences.accountList = AccountList(entries: [
            .account(c),
            .pool(AccountPool(id: poolID, label: "Team", agent: .claude, members: [a, b])),
        ])
        configureLedger()
    }

    private func configureLedger() {
        ledger.configure(pools: store.effectivePools,
                         accounts: store.preferences.accounts.map(CapacityPreferences.accountRef))
    }

    private func assign(_ assignment: AccountAssignment?, agent: AgentID = .claude) {
        var settings = store.projectSettings(project)
        settings.accounts[agent] = assignment
        store.setProjectSettings(project, settings)
    }

    private func read(_ account: AgentAccount, _ utilization: Double) {
        ledger.ingest(UsageReading(account: CapacityPreferences.accountRef(account),
                                   windows: [UsageWindow(name: "5h", utilization: utilization, resetsAt: nil)],
                                   readAt: now, source: "test", hardRejection: false))
    }

    private func resolver() -> AccountResolver { AccountResolver(preferences: store, ledger: ledger) }

    // MARK: Unassigned and account assignments

    func testAnUnassignedProjectRunsOnTheAgentsFirstLiveAccountWithNoLease() throws {
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, c.id, "list order: the top-level C comes before the pool")
        XCTAssertNil(r.lease)
        XCTAssertEqual(r.source, .unassigned)
    }

    func testAnAccountAssignmentRunsOnThatAccount() throws {
        assign(.account(b.id))
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, b.id)
        XCTAssertNil(r.lease)
    }

    func testARemovedAssignedAccountIsMissingNotAnotherLogin() {
        assign(.account(b.id))
        store.preferences.accountList.accounts = store.preferences.accounts.map {
            var x = $0; if x.id == self.b.id { x.removedAt = now }; return x
        }
        XCTAssertEqual(resolver().resolve(agent: .claude, project: project), .failure(.accountMissing(.claude)))
    }

    // MARK: Pool leasing

    func testAPoolLeasesItsFirstAccountUnderSoftAndHoldsTheLease() throws {
        assign(.pool(poolID))
        read(a, 0.90)   // over soft (0.80)
        read(b, 0.10)
        let resolver = resolver()
        let r = try resolver.resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, b.id, "A is over soft, so the lease skips to B")
        XCTAssertEqual(r.source, .pool(poolID))
        XCTAssertNil(r.fallback)
        let lease = try XCTUnwrap(r.lease)
        XCTAssertEqual(ledger.activeLeases(pool: poolID), [lease])

        let tab = UUID()
        resolver.hold(r, for: tab)
        XCTAssertEqual(resolver.leases(heldBy: tab), [lease])
        resolver.release(holder: tab)
        XCTAssertEqual(ledger.activeLeases(pool: poolID), [], "closing the tab gives the lease back")
        XCTAssertEqual(resolver.leases(heldBy: tab), [])
    }

    func testAPreviewPicksTheSameAccountWithoutLeasing() throws {
        assign(.pool(poolID))
        read(a, 0.90)
        read(b, 0.10)
        let r = try resolver().resolve(agent: .claude, project: project, leasing: false).get()
        XCTAssertEqual(r.account?.id, b.id)
        XCTAssertNil(r.lease)
        XCTAssertEqual(ledger.activeLeases(pool: poolID), [])
    }

    func testWithNoReadingsThePoolLeasesItsFirstMember() throws {
        assign(.pool(poolID))
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, a.id, "every member unknown: LeasePolicy takes the first unknown")
        XCTAssertNotNil(r.lease)
    }

    func testEveryMemberOverSoftButUnderHardRunsOnTheFirstSuchMemberWithoutANotice() throws {
        assign(.pool(poolID))
        read(a, 0.90)
        read(b, 0.85)
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, a.id)
        XCTAssertEqual(r.fallback, .overSoft)
        XCTAssertNil(r.lease, "the ledger leases nothing over soft")
        XCTAssertNil(r.notice)
    }

    /// No account under hard: the work still starts — on the member with the most headroom,
    /// never on a login outside the pool — and the caller is handed a notice to show.
    func testEveryMemberOverHardFallsBackToTheLeastUsedMemberAndSaysSo() throws {
        assign(.pool(poolID))
        read(a, 0.99)
        read(b, 0.96)
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, b.id)
        XCTAssertEqual(r.fallback, .allOverHard)
        XCTAssertNil(r.lease)
        let notice = try XCTUnwrap(r.notice)
        XCTAssertTrue(notice.title.contains("Team"), notice.title)
        XCTAssertTrue(notice.body.contains("B"), notice.body)
    }

    /// The ledger is reconfigured one hop after a preferences change, so a pool made a moment
    /// ago can be unknown to it. That must not refuse the launch.
    func testAPoolTheLedgerHasNotSeenYetRunsOnItsFirstMemberUntracked() throws {
        ledger.configure(pools: [], accounts: [])
        assign(.pool(poolID))
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, a.id)
        XCTAssertEqual(r.fallback, .untracked)
        XCTAssertNil(r.lease)
        XCTAssertNil(r.notice)
    }

    func testAMissingPoolIsRefused() {
        assign(.pool("nope"))
        XCTAssertEqual(resolver().resolve(agent: .claude, project: project),
                       .failure(.poolUnavailable("nope", .claude)))
    }

    func testAPoolWhoseMembersWereAllRemovedIsRefused() {
        assign(.pool(poolID))
        store.preferences.accountList.accounts = store.preferences.accounts.map {
            var x = $0; if x.id != self.c.id { x.removedAt = now }; return x
        }
        configureLedger()
        XCTAssertEqual(resolver().resolve(agent: .claude, project: project),
                       .failure(.poolUnavailable(poolID, .claude)))
    }

    func testAPoolOfAnotherAgentIsRefused() {
        assign(.pool(poolID), agent: .codex)
        XCTAssertEqual(resolver().resolve(agent: .codex, project: project),
                       .failure(.poolUnavailable(poolID, .codex)))
    }

    func testReleasingAnUnheldResolutionGivesItsLeaseBack() throws {
        assign(.pool(poolID))
        let resolver = resolver()
        let r = try resolver.resolve(agent: .claude, project: project).get()
        XCTAssertEqual(ledger.activeLeases(pool: poolID).count, 1)
        resolver.release(r)
        XCTAssertEqual(ledger.activeLeases(pool: poolID), [])
    }

    func testOneHolderCanHoldSeveralAgentsLeases() throws {
        let codex = AgentAccount(agent: .codex, displayName: "X", home: URL(fileURLWithPath: "/tmp/fd-resolver/x"))
        try store.updateAccountList { list throws(AccountListError) in
            try list.addPool(AccountPool(id: "codex-team", label: "CT", agent: .codex, members: [codex]))
        }
        configureLedger()
        assign(.pool(poolID))
        assign(.pool("codex-team"), agent: .codex)
        let resolver = resolver()
        let run = UUID()
        resolver.hold(try resolver.resolve(agent: .claude, project: project).get(), for: run)
        resolver.hold(try resolver.resolve(agent: .codex, project: project).get(), for: run)
        XCTAssertEqual(resolver.leases(heldBy: run).count, 2)
        resolver.release(holder: run)
        XCTAssertEqual(ledger.activeLeases(pool: poolID), [])
        XCTAssertEqual(ledger.activeLeases(pool: "codex-team"), [])
    }

    func testHomeIsTheAccountsOrTheBuiltIn() throws {
        assign(.account(b.id))
        XCTAssertEqual(try resolver().resolve(agent: .claude, project: project).get().home, b.home)
        XCTAssertEqual(AccountResolution(agent: .grok, account: nil, source: .unassigned).home,
                       AgentID.grok.builtInHome)
    }
}
