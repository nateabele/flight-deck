import FleetKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// An explicit default account or pool per agent (Settings → Accounts' Make Default): what it
/// stores, what it changes in resolution, when it clears, and how the panes show it.
@MainActor
final class AgentAccountDefaultTests: XCTestCase {
    private let project = "/tmp/fd-default-project"
    private var store: PreferencesStore!
    private var ledger: CapacityLedger!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var a: AgentAccount!
    private var b: AgentAccount!
    private var c: AgentAccount!
    private var x: AgentAccount!
    private let team: PoolID = "claude-team"

    override func setUp() async throws {
        store = PreferencesStore(persistence: nil)
        let fixed = now
        ledger = CapacityLedger(now: { fixed })
        let root = URL(fileURLWithPath: "/tmp/fd-default", isDirectory: true)
        a = AgentAccount(agent: .claude, displayName: "A", home: root.appendingPathComponent("a"))
        b = AgentAccount(agent: .claude, displayName: "B", home: root.appendingPathComponent("b"))
        c = AgentAccount(agent: .claude, displayName: "C", home: root.appendingPathComponent("c"))
        x = AgentAccount(agent: .codex, displayName: "X", home: root.appendingPathComponent("x"))
        store.preferences.accountList = AccountList(entries: [
            .account(c),
            .account(x),
            .pool(AccountPool(id: team, label: "Team", agent: .claude, members: [a, b])),
        ])
        configureLedger()
    }

    private func configureLedger() {
        ledger.configure(pools: store.effectivePools,
                         accounts: store.preferences.accounts.map(CapacityPreferences.accountRef))
    }

    private func resolver() -> AccountResolver { AccountResolver(preferences: store, ledger: ledger) }

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

    private func tombstone(_ account: AgentAccount) {
        store.preferences.accountList.accounts = store.preferences.accounts.map {
            var copy = $0
            if copy.id == account.id { copy.removedAt = now }
            return copy
        }
    }

    // MARK: Storage

    func testTheDefaultRoundTripsThroughPreferences() throws {
        store.setAccountDefault(.pool(team), for: .claude)
        store.setAccountDefault(.account(x.id), for: .codex)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(store.preferences))
        XCTAssertEqual(decoded.agentAccountDefaults, [.claude: .pool(team), .codex: .account(x.id)])
    }

    func testNothingChosenWritesNoKey() throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.preferences)) as? [String: Any]
        XCTAssertNil(encoded?["storedAgentAccountDefaults"], "an untouched install stays byte-compatible")
        store.setAccountDefault(.account(c.id), for: .claude)
        store.setAccountDefault(nil, for: .claude)
        XCTAssertNil(store.preferences.storedAgentAccountDefaults, "clearing the last choice removes the key again")
    }

    /// Older builds decode with synthesized Codable, which ignores keys it does not know; a
    /// later build's agent costs that entry, not the file.
    func testAnOlderBlobWithoutTheKeyDecodesAndALaterAgentCostsOnlyItsEntry() throws {
        var blob = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        XCTAssertNil(blob["storedAgentAccountDefaults"])
        XCTAssertNoThrow(try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: blob)))

        blob["storedAgentAccountDefaults"] = [
            "accounts": ["claude": a.id.uuidString, "futureagent": UUID().uuidString],
            "pools": ["codex": "pool-x", "alsofuture": "pool-y"],
        ]
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: blob))
        XCTAssertEqual(decoded.agentAccountDefaults, [.claude: .account(a.id), .codex: .pool("pool-x")])
    }

    func testAMalformedDefaultsBlockIsDroppedNotFatal() throws {
        var blob = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        blob["storedAgentAccountDefaults"] = ["accounts": "nonsense", "pools": [1, 2]]
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: blob))
        XCTAssertEqual(decoded.agentAccountDefaults, [:])
    }

    // MARK: Invalidation

    func testRemovingTheDefaultAccountClearsIt() {
        store.setAccountDefault(.account(b.id), for: .claude)
        store.markAccountRemoved(id: b.id)
        XCTAssertNil(store.accountDefault(for: .claude))
    }

    func testRemovingAnotherAccountKeepsTheDefault() {
        store.setAccountDefault(.account(b.id), for: .claude)
        store.markAccountRemoved(id: c.id)
        XCTAssertEqual(store.accountDefault(for: .claude), .account(b.id))
    }

    func testDeletingTheDefaultPoolClearsIt() throws {
        store.setAccountDefault(.pool(team), for: .claude)
        try store.removePool(team)
        XCTAssertNil(store.accountDefault(for: .claude))
    }

    func testMovingTheDefaultAccountIntoOrOutOfAPoolKeepsItTheDefault() throws {
        store.setAccountDefault(.account(c.id), for: .claude)
        try store.updateAccountList { list throws(AccountListError) in try list.move(account: c.id, toPool: team) }
        XCTAssertEqual(store.effectiveAccountDefault(for: .claude), .account(c.id))
        try store.updateAccountList { list throws(AccountListError) in try list.move(account: c.id, toPool: nil) }
        XCTAssertEqual(store.effectiveAccountDefault(for: .claude), .account(c.id))
    }

    func testAStaleDefaultReadsAsUnset() {
        // Written straight to storage, the way a file edited by hand or by an older build could be.
        store.preferences.storedAgentAccountDefaults = AgentAccountDefaults([.claude: .account(UUID()), .codex: .pool("nope")])
        XCTAssertNil(store.effectiveAccountDefault(for: .claude))
        XCTAssertNil(store.effectiveAccountDefault(for: .codex))
        store.preferences.storedAgentAccountDefaults = AgentAccountDefaults([.claude: .account(x.id)])
        XCTAssertNil(store.effectiveAccountDefault(for: .claude), "another agent's account is no default")
    }

    // MARK: Resolution

    func testWithNoDefaultAnUnassignedProjectStillRunsOnTheTopmostAccount() throws {
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, c.id)
        XCTAssertEqual(store.account(for: .claude, project: project)?.id, c.id)
    }

    func testAnUnassignedProjectRunsOnTheDefaultAccount() throws {
        store.setAccountDefault(.account(b.id), for: .claude)
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, b.id)
        XCTAssertNil(r.lease)
        XCTAssertEqual(store.account(for: .claude, project: project)?.id, b.id)
        XCTAssertEqual(store.resolvedAccounts(for: store.preferences.agents, project: project)[.claude], b.id,
                       "the New Session menu's checkmark agrees")
    }

    func testAnUnassignedProjectLeasesFromTheDefaultPoolAsIfItNamedIt() throws {
        store.setAccountDefault(.pool(team), for: .claude)
        read(a, 0.90)   // over soft
        read(b, 0.10)
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, b.id, "A is over soft, so the lease skips to B")
        XCTAssertEqual(r.source, .pool(team))
        let lease = try XCTUnwrap(r.lease)
        XCTAssertEqual(ledger.activeLeases(pool: team), [lease])
    }

    func testTheDefaultPoolKeepsThePoolFallbacksAndNotices() throws {
        store.setAccountDefault(.pool(team), for: .claude)
        read(a, 0.99)
        read(b, 0.98)
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.fallback, .allOverHard)
        XCTAssertEqual(r.notice?.title, "Every account in “Team” is over its limit")
    }

    func testAProjectsOwnAssignmentBeatsTheDefault() throws {
        store.setAccountDefault(.pool(team), for: .claude)
        assign(.account(c.id))
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, c.id)
        XCTAssertNil(r.lease)
    }

    func testATombstonedDefaultAccountIsIgnored() throws {
        store.preferences.storedAgentAccountDefaults = AgentAccountDefaults([.claude: .account(b.id)])
        tombstone(b)
        let r = try resolver().resolve(agent: .claude, project: project).get()
        XCTAssertEqual(r.account?.id, c.id, "back to the topmost, never a refusal")
    }

    func testADefaultIsPerAgent() throws {
        store.setAccountDefault(.pool(team), for: .claude)
        let r = try resolver().resolve(agent: .codex, project: project).get()
        XCTAssertEqual(r.account?.id, x.id)
    }

    func testTheCapabilityIndexUsesTheAgentDefaultWhenItsOwnIsUnset() throws {
        store.setAccountDefault(.account(b.id), for: .claude)
        XCTAssertEqual(resolver().indexAssignment(.claude), .account(b.id))
        let r = try resolver().resolveIndex(agent: .claude).get()
        XCTAssertEqual(r.account?.id, b.id)
        store.indexAccount = .account(c.id)
        XCTAssertEqual(resolver().indexAssignment(.claude), .account(c.id), "its own choice still wins")
    }

    // MARK: Thaw, rollover and reacquire

    func testThawRollsOverWithinTheDefaultPoolForAProjectThatNamesNothing() throws {
        store.setAccountDefault(.pool(team), for: .claude)
        read(a, 0.99)
        read(b, 0.10)
        let plan = resolver().thawPlan(agent: .claude, project: project, account: a, blocked: nil)
        guard case .rollOver(let to, let resolution) = plan else { return XCTFail("expected a rollover, got \(plan)") }
        XCTAssertEqual(to.id, b.id)
        XCTAssertEqual(resolution.source, .pool(team))
        resolver().release(resolution)
    }

    func testThawIsAPlainWakeWithoutADefaultPool() {
        read(a, 0.99)
        read(b, 0.10)
        XCTAssertEqual(resolver().thawPlan(agent: .claude, project: project, account: a, blocked: nil), .inPlace(nil))
    }

    func testReacquireLeasesTheStampedAccountInTheDefaultPool() {
        store.setAccountDefault(.pool(team), for: .claude)
        let resolver = resolver()
        let tab = UUID()
        XCTAssertTrue(resolver.reacquire(agent: .claude, project: project, account: a, for: tab))
        XCTAssertEqual(resolver.leases(heldBy: tab).map(\.account.id), [a.id])
        XCTAssertFalse(resolver.reacquire(agent: .claude, project: project, account: c, for: UUID()),
                       "an account outside the pool runs on no pool")
    }

    func testReacquireDoesNothingWithoutAPoolInEffect() {
        store.setAccountDefault(.account(a.id), for: .claude)
        XCTAssertFalse(resolver().reacquire(agent: .claude, project: project, account: a, for: UUID()))
    }

    // MARK: /switch-account

    func testChoicesMarkTheDefaultPoolAsAssignedForAProjectThatNamesNothing() {
        let resolver = resolver()
        XCTAssertEqual(resolver.choices(agent: .claude, project: project, current: a).pools.map(\.isAssigned), [false])
        store.setAccountDefault(.pool(team), for: .claude)
        XCTAssertEqual(resolver.choices(agent: .claude, project: project, current: a).pools.map(\.isAssigned), [true])
        assign(.account(c.id))
        XCTAssertEqual(resolver.choices(agent: .claude, project: project, current: a).pools.map(\.isAssigned), [false],
                       "the project's own assignment is the one in effect")
    }

    // MARK: Settings → Accounts

    private func group(_ agent: AgentID = .claude) -> AccountsPaneModel.Group {
        AccountsPaneModel.groups(store.preferences.accountList, defaults: store.preferences.agentAccountDefaults)
            .first { $0.agent == agent }!
    }

    func testTheCapsuleSitsOnTheTopmostAccountUntilAnAccountIsChosen() {
        XCTAssertEqual(group().defaultAccountID, c.id)
        XCTAssertFalse(group().isDefaultExplicit)
        store.setAccountDefault(.account(b.id), for: .claude)
        XCTAssertEqual(group().defaultAccountID, b.id, "a pool member can be the default")
        XCTAssertNil(group().defaultPoolID)
        XCTAssertTrue(group().isDefaultExplicit)
    }

    func testTheCapsuleMovesToAPoolHeaderWhenAPoolIsTheDefault() {
        store.setAccountDefault(.pool(team), for: .claude)
        XCTAssertEqual(group().defaultPoolID, team)
        XCTAssertNil(group().defaultAccountID)
    }

    func testMakeDefaultIsOfferedOnEveryRowButTheChosenOne() {
        let pool = store.preferences.accountList.pool(team)!
        XCTAssertEqual(AccountsPaneModel.makeDefaultTarget(.account(c), in: group()), .account(c.id))
        XCTAssertEqual(AccountsPaneModel.makeDefaultTarget(.member(a, pool: team), in: group()), .account(a.id))
        XCTAssertEqual(AccountsPaneModel.makeDefaultTarget(.pool(pool), in: group()), .pool(team))
        store.setAccountDefault(.pool(team), for: .claude)
        XCTAssertNil(AccountsPaneModel.makeDefaultTarget(.pool(pool), in: group()), "already the default")
        XCTAssertEqual(AccountsPaneModel.makeDefaultTarget(.account(c), in: group()), .account(c.id))
    }

    func testMakeDefaultIsNotOfferedForRemovedAccountsLocalPoolsTheUnpooledPoolOrGemini() {
        var gone = c!
        gone.removedAt = now
        XCTAssertNil(AccountsPaneModel.makeDefaultTarget(.account(gone), in: group()))
        let local = AccountPool(id: "box", label: "Box", agent: .claude, kind: .local)
        XCTAssertNil(AccountsPaneModel.makeDefaultTarget(.pool(local), in: group()))
        let unpooled = AccountPool(id: CapacityPool.defaultID(for: .claude), label: "Claude default", agent: .claude)
        XCTAssertNil(AccountsPaneModel.makeDefaultTarget(.pool(unpooled), in: group()))
        let g = AgentAccount(agent: .gemini, displayName: "G", home: URL(fileURLWithPath: "/tmp/fd-default/g"))
        XCTAssertNil(AccountsPaneModel.makeDefaultTarget(.account(g), in: group(.gemini)))
    }

    func testTheClearItemAppearsOnlyWhileAChoiceIsInForce() {
        XCTAssertFalse(AccountsPaneModel.canClearDefault(in: group()))
        store.setAccountDefault(.account(b.id), for: .claude)
        XCTAssertTrue(AccountsPaneModel.canClearDefault(in: group()))
        store.setAccountDefault(nil, for: .claude)
        XCTAssertFalse(AccountsPaneModel.canClearDefault(in: group()))
    }

    func testTheCapsuleFollowsARemovalBackToTheTopmost() throws {
        store.setAccountDefault(.account(b.id), for: .claude)
        store.markAccountRemoved(id: b.id)
        XCTAssertEqual(group().defaultAccountID, c.id)
        store.setAccountDefault(.pool(team), for: .claude)
        try store.removePool(team)
        XCTAssertNil(group().defaultPoolID)
        XCTAssertFalse(group().isDefaultExplicit)
    }

    func testTheFooterNamesWhatIsInEffect() {
        let list = store.preferences.accountList
        XCTAssertEqual(AccountsPaneModel.footer(for: group(), in: list),
                       "Projects that haven't chosen an account use “C”, the topmost.")
        store.setAccountDefault(.account(b.id), for: .claude)
        XCTAssertEqual(AccountsPaneModel.footer(for: group(), in: store.preferences.accountList),
                       "Projects that haven't chosen an account use “B”.")
        store.setAccountDefault(.pool(team), for: .claude)
        XCTAssertEqual(AccountsPaneModel.footer(for: group(), in: store.preferences.accountList),
                       "Projects that haven't chosen an account use the “Team” pool.")
    }

    // MARK: Settings → Projects

    func testTheProjectPickersDefaultNamesTheEffectiveDefault() {
        let list = store.preferences.accountList
        XCTAssertEqual(ProjectsSettingsTab.accountOptions(for: .claude, in: list)[0].title, "Default (C)")
        XCTAssertEqual(ProjectsSettingsTab.accountOptions(for: .claude, in: list, agentDefault: .account(b.id))[0].title,
                       "Default (B)")
        XCTAssertEqual(ProjectsSettingsTab.accountOptions(for: .claude, in: list, agentDefault: .pool(team))[0].title,
                       "Default (Team pool)")
        XCTAssertEqual(ProjectsSettingsTab.accountOptions(for: .claude, in: list, agentDefault: .pool("gone"))[0].title,
                       "Default (C)", "a stale default reads as the topmost")
    }
}
