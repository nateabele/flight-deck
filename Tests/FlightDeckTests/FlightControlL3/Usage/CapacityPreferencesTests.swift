import XCTest
import IntakeKit
@testable import FlightDeck

/// Pools are the user's words for capacity, stored in preferences; the default pools are what
/// every user has without touching Settings. These pin that the defaults track the account list
/// the user already curates, that an edited pool keeps its order while new accounts still join,
/// that a removed account never reappears in a pool, and that an old preferences blob decodes.
@MainActor
final class CapacityPreferencesTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/fd-capacity-prefs", isDirectory: true)
    private lazy var work = AgentAccount(id: UsageRefs.workID, agent: .claude, displayName: "Work", home: home.appendingPathComponent("w"))
    private lazy var spare = AgentAccount(id: UsageRefs.spareID, agent: .claude, displayName: "Spare", home: home.appendingPathComponent("s"))
    private lazy var codex = AgentAccount(id: UsageRefs.codexID, agent: .codex, displayName: "Codex", home: home.appendingPathComponent("c"))

    func testDefaultPoolsHoldEachAgentsLiveAccountsInOrder() {
        let pools = CapacityPreferences().effectivePools(accounts: [work, codex, spare])
        XCTAssertEqual(pools.map(\.id), ["claude-default", "codex-default"])
        XCTAssertEqual(pools[0].accounts, [UsageRefs.workID, UsageRefs.spareID])
        XCTAssertEqual(pools[0].label, "Claude default")
        XCTAssertEqual(pools[0].harness, "claude")
        XCTAssertEqual(pools[0].softThreshold, 0.80)
        XCTAssertEqual(pools[0].hardThreshold, 0.95)
        XCTAssertEqual(pools[1].accounts, [UsageRefs.codexID])
    }

    func testAnAgentWithNoAccountsHasNoDefaultPool() {
        XCTAssertEqual(CapacityPreferences().effectivePools(accounts: [codex]).map(\.id), ["codex-default"])
    }

    func testAStoredDefaultPoolKeepsItsOrderAndGainsNewAccounts() {
        var stored = CapacityPool.hosted(id: "claude-default", label: "Claude default", harness: "claude", accounts: [UsageRefs.spareID, UsageRefs.workID])
        stored.softThreshold = 0.7
        let newcomer = AgentAccount(agent: .claude, displayName: "New", home: home.appendingPathComponent("n"))
        let pools = CapacityPreferences(pools: [stored]).effectivePools(accounts: [work, spare, newcomer])
        XCTAssertEqual(pools.first?.accounts, [UsageRefs.spareID, UsageRefs.workID, newcomer.id])
        XCTAssertEqual(pools.first?.softThreshold, 0.7)
    }

    func testUserPoolsFollowTheDefaultsAndDropDeletedAccounts() {
        let gone = UUID()
        let mine = CapacityPool.hosted(id: "pool-abc12345", label: "Night shift", harness: "claude", accounts: [gone, UsageRefs.spareID])
        let pools = CapacityPreferences(pools: [mine]).effectivePools(accounts: [work, spare])
        XCTAssertEqual(pools.map(\.id), ["claude-default", "pool-abc12345"])
        XCTAssertEqual(pools[1].accounts, [UsageRefs.spareID])
    }

    func testALocalPoolPassesThroughUntouched() {
        let local = CapacityPool.local(id: "pool-local001", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434")
        XCTAssertEqual(CapacityPreferences(pools: [local]).effectivePools(accounts: [work]).last, local)
    }

    func testHandoffSettingsDefaults() {
        XCTAssertEqual(CapacityPreferences().handoffSettings, HandoffSettings(confirm: false, deadline: 600))
        XCTAssertEqual(CapacityPreferences(confirmHandoffs: true, handoffDeadlineSeconds: 120).handoffSettings,
                       HandoffSettings(confirm: true, deadline: 120))
    }

    func testAnOldPreferencesBlobStillDecodes() throws {
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        old.removeValue(forKey: "capacity")
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.capacity)
    }

    func testPreferencesStoreRoundTripsAnEdit() {
        let store = PreferencesStore(persistence: nil)
        store.updateCapacity { $0.confirmHandoffs = true }
        XCTAssertEqual(store.capacity.confirmHandoffs, true)
        XCTAssertEqual(store.preferences.capacity?.confirmHandoffs, true)
    }

    /// Review focus: removing an account tombstones it while its tab runs. The running tab keeps
    /// reporting under the same id — so the ledger must record it — but no pool may lease it.
    func testTombstonedAccountIsMeteredButNeverLeased() {
        var removed = work
        removed.removedAt = Date()
        let accounts = [removed, spare]
        let ledger = CapacityLedger()
        ledger.configure(pools: CapacityPreferences().effectivePools(accounts: accounts),
                         accounts: accounts.map(CapacityPreferences.accountRef))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.05, at: Date()))
        XCTAssertEqual(ledger.latestReading(account: UsageRefs.workID)?.worstWindow?.utilization, 0.05)
        XCTAssertEqual(ledger.pool("claude-default")?.accounts, [UsageRefs.spareID])
        XCTAssertEqual(ledger.lease(pool: "claude-default")?.account.id, UsageRefs.spareID,
                       "the removed account has the most headroom and must still never be chosen")
    }
}
