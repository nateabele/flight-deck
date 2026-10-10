import XCTest
import IntakeKit
@testable import FlightDeck

/// The capability index bills its own account assignment (round 2, index-refresh-pool): an
/// account or a pool chosen on its Settings pane, and — when nothing is chosen — claude's pool,
/// leased through `CapacityLedger` like a tab on a pool. Before this the refresh resolved with
/// its work directory as a "project" nobody assigns, so it always billed claude's first live
/// account and never leased: a weekly refresh could land on an account already over its limit
/// while the pool had headroom elsewhere.
@MainActor
final class IndexAccountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_093_600)
    private var dir: URL!
    private var prefs: PreferencesStore!
    private var ledger: CapacityLedger!
    private var resolver: AccountResolver!

    private var a: AgentAccount!
    private var b: AgentAccount!
    private var c: AgentAccount!
    private let team: PoolID = "claude-team"

    override func setUp() async throws {
        dir = IndexFixtures.scratch()
        let d = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        prefs = PreferencesStore(persistence: nil)
        let fixed = now
        ledger = CapacityLedger(now: { fixed })
        let root = URL(fileURLWithPath: "/tmp/fd-index-account", isDirectory: true)
        a = AgentAccount(agent: .claude, displayName: "A", home: root.appendingPathComponent("a"))
        b = AgentAccount(agent: .claude, displayName: "B", home: root.appendingPathComponent("b"))
        c = AgentAccount(agent: .claude, displayName: "C", home: root.appendingPathComponent("c"))
        setList([.account(c), .pool(AccountPool(id: team, label: "Team", agent: .claude, members: [a, b]))])
        resolver = AccountResolver(preferences: prefs, ledger: ledger)
    }

    private func setList(_ entries: [AccountEntry]) {
        prefs.preferences.accountList = AccountList(entries: entries)
        ledger.configure(pools: prefs.effectivePools, accounts: prefs.preferences.accounts.map(CapacityPreferences.accountRef))
    }

    private func read(_ account: AgentAccount, _ utilization: Double) {
        ledger.ingest(UsageReading(account: CapacityPreferences.accountRef(account),
                                   windows: [UsageWindow(name: "5h", utilization: utilization, resetsAt: nil)],
                                   readAt: now, source: "test", hardRejection: false))
    }

    private func seedConfig() throws {
        var config = IndexConfig.initial()
        config.sources = [IndexFixtures.source("a")]
        config.aliases.set(source: "a", benchmarkModel: "GPT-6 Sol (high)", model: IndexFixtures.sol, status: .confirmed)
        try config.save(to: dir.appendingPathComponent("config.json"))
    }

    private func service(_ headless: HeadlessRunner) -> CapabilityIndexService {
        let t = now
        let s = CapabilityIndexService(directory: dir, runner: IndexRefreshRunner(headless: headless, now: { t }),
                                       catalogs: { IndexFixtures.catalogs() }, now: { t })
        s.accountResolver = resolver
        return s
    }

    private var answer: Data {
        IndexFixtures.stream(IndexFixtures.payloadJSON("a", [("GPT-6 Sol (high)", 61.3)]))
    }

    // MARK: Which assignment the index uses

    func testUnsetWithExactlyOneUserPoolLeasesFromThatPool() throws {
        read(a, 0.9)   // over soft: the lease skips to B, as a tab's would
        read(b, 0.1)
        let r = try resolver.acquireIndexAccount(.claude).get()
        XCTAssertEqual(r.account?.id, b.id)
        let lease = try XCTUnwrap(r.lease, "an unset index assignment must lease from claude's pool")
        XCTAssertEqual(lease.pool, team)
        XCTAssertEqual(ledger.activeLeases(pool: team), [lease])
    }

    func testUnsetWithTwoUserPoolsLeasesFromClaudeDefault() throws {
        let other = AgentAccount(agent: .claude, displayName: "D", home: URL(fileURLWithPath: "/tmp/fd-index-account/d"))
        setList([.account(c), .pool(AccountPool(id: team, label: "Team", agent: .claude, members: [a, b])),
                 .pool(AccountPool(id: "claude-solo", label: "Solo", agent: .claude, members: [other]))])
        let r = try resolver.acquireIndexAccount(.claude).get()
        XCTAssertEqual(r.lease?.pool, CapacityPool.defaultID(for: .claude), "two user pools: no guessing, the default pool")
        XCTAssertEqual(r.account?.id, c.id, "claude-default holds the unpooled account")
    }

    func testUnsetWithNoUserPoolLeasesFromClaudeDefault() throws {
        setList([.account(c), .account(a)])
        let r = try resolver.acquireIndexAccount(.claude).get()
        XCTAssertEqual(r.lease?.pool, CapacityPool.defaultID(for: .claude))
        XCTAssertEqual(r.account?.id, c.id)
    }

    func testUnsetWithNoClaudeAccountRunsInTheBuiltInHome() throws {
        setList([])
        let r = try resolver.acquireIndexAccount(.claude).get()
        XCTAssertNil(r.account, "no account record at all: the built-in home, as before accounts existed")
        XCTAssertNil(r.lease)
    }

    func testAnAccountAssignmentRunsOnThatAccountWithoutALease() throws {
        prefs.indexAccount = .account(a.id)
        let r = try resolver.acquireIndexAccount(.claude).get()
        XCTAssertEqual(r.account?.id, a.id)
        XCTAssertNil(r.lease)
    }

    func testAPoolAssignmentThatNoLongerExistsIsRefused() {
        prefs.indexAccount = .pool("gone")
        XCTAssertEqual(resolver.acquireIndexAccount(.claude).map(\.account), .failure(.poolUnavailable("gone", .claude)))
    }

    func testTheAssignmentPersistsInFlightControlPreferences() throws {
        prefs.indexAccount = .pool(team)
        let data = try JSONEncoder().encode(prefs.preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded.capacity?.indexAccount, .pool(team))
        prefs.indexAccount = .account(a.id)
        let again = try JSONDecoder().decode(Preferences.self, from: try JSONEncoder().encode(prefs.preferences))
        XCTAssertEqual(again.capacity?.indexAccount, .account(a.id))
        prefs.indexAccount = nil
        XCTAssertNil(prefs.preferences.capacity?.indexAccount)
    }

    func testTheDefaultChoiceNamesThePoolItWillUse() {
        XCTAssertEqual(AccountResolver.defaultIndexPool(for: .claude, in: prefs.effectivePools), team)
        let options = IndexAccountChoices.options(for: .claude, in: prefs.preferences.accountList)
        XCTAssertEqual(options.first?.value, nil)
        XCTAssertEqual(options.first?.title, "Default (Team pool)")
        XCTAssertTrue(options.contains { $0.value == .pool(team) && $0.isPool })
        XCTAssertTrue(options.contains { $0.value == .account(a.id) && !$0.isPool })
    }

    // MARK: The lease lifecycle of a refresh

    func testARefreshHoldsAPoolLeaseWhileItRunsAndReleasesItOnSuccess() async throws {
        try seedConfig()
        read(a, 0.1)
        let gate = GatedIndexHeadless(answer: answer)
        let s = service(gate)
        let task = s.startRefresh()
        while !gate.hasStarted { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(ledger.activeLeases(pool: team).map(\.account.id), [a.id], "the refresh runs on a lease from the pool")
        gate.release()
        await task?.value
        XCTAssertEqual(ledger.activeLeases(pool: team), [], "released once the refresh succeeds")
        XCTAssertNotNil(s.current)
    }

    func testARefreshWhoseSourcesFailStillReleasesItsLease() async throws {
        try seedConfig()
        let h = ScriptedIndexHeadless()   // unscripted: every source exits 1
        let s = service(h)
        await s.refreshNow()
        XCTAssertEqual(h.accounts.count, 1, "the source did run")
        XCTAssertEqual(ledger.activeLeases(pool: team), [], "released after a failed refresh")
    }

    func testACancelledRefreshStopsTheRunAndReleasesItsLease() async throws {
        try seedConfig()
        let h = StreamingIndexHeadless(tokens: 10)   // runs until its task is cancelled
        let s = service(h)
        let task = s.startRefresh()
        while h.ran.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(ledger.activeLeases(pool: team).count, 1)
        s.cancelRefresh()
        await task?.value
        XCTAssertTrue(h.cancelled, "cancel must stop the running claude, not wait it out")
        XCTAssertEqual(ledger.activeLeases(pool: team), [], "released after a cancelled refresh")
        XCTAssertFalse(s.isRefreshing)
        XCTAssertNil(s.current, "a cancelled refresh writes no snapshot")
    }

    func testARefusedRefreshLeasesNothing() async throws {
        try seedConfig()
        prefs.indexAccount = .pool("gone")
        let h = ScriptedIndexHeadless()
        let s = service(h)
        await s.refreshNow()
        XCTAssertEqual(h.ran, [])
        XCTAssertNotNil(s.problem)
        XCTAssertEqual(ledger.activeLeases(pool: team), [])
    }

    // MARK: Usage reaches the leased account

    func testTheRefreshsRateLimitWindowsMeterTheLeasedAccount() async throws {
        try seedConfig()
        read(a, 0.9)
        read(b, 0.1)   // so the lease lands on B
        let h = ScriptedIndexHeadless()
        let event = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.42,"resetsAt":1791100000}}}}"# + "\n"
        h.answers["a"] = (Data(event.utf8) + answer, "", 0)
        let s = service(h)
        await s.refreshNow()
        let seat = try XCTUnwrap(s.seatActivities.first)
        XCTAssertEqual(seat.accountID, b.id, "the source's run is credited to the account the refresh leased")
        XCTAssertNotNil(seat.rateLimitWindows)

        let accounts = prefs.preferences.accounts
        var env = UsageEnvironment.empty
        env.accounts = { accounts }
        env.seatActivities = { s.seatActivities }
        let usage = UsageService(environment: env, ledger: ledger, now: { self.now })
        await usage.tick()
        XCTAssertEqual(ledger.latestReading(account: b.id)?.source, "claude headless")
        XCTAssertEqual(ledger.latestReading(account: b.id)?.windows.first?.utilization ?? 0, 0.42, accuracy: 1e-9)
    }
}
