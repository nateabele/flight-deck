import XCTest
import IntakeKit
@testable import FlightDeck

/// The hand-off settings stored beside the pools' legacy mirror, and that a removed account is
/// metered but never leased. The pools themselves are the Accounts list's (unify brief R6):
/// their derivation is pinned by `AccountListTests`.
@MainActor
final class CapacityPreferencesTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/fd-capacity-prefs", isDirectory: true)
    private lazy var work = AgentAccount(id: UsageRefs.workID, agent: .claude, displayName: "Work", home: home.appendingPathComponent("w"))
    private lazy var spare = AgentAccount(id: UsageRefs.spareID, agent: .claude, displayName: "Spare", home: home.appendingPathComponent("s"))
    private lazy var codex = AgentAccount(id: UsageRefs.codexID, agent: .codex, displayName: "Codex", home: home.appendingPathComponent("c"))

    func testHandoffSettingsDefaults() {
        XCTAssertEqual(CapacityPreferences().handoffSettings, HandoffSettings(confirm: false, deadline: 600))
        XCTAssertEqual(CapacityPreferences(handoffDeadlineSeconds: 120).handoffSettings,
                       HandoffSettings(confirm: false, deadline: 120))
    }

    /// Nothing can answer a hand-off confirmation yet (the phone shows no Confirm/Decline and the
    /// Mac has no action), so a stored "Confirm hand-offs" — set before the toggle was disabled,
    /// or by hand — would park every over-limit agent on its exhausted account forever.
    func testConfirmIsOffEvenWhenTheStoredFlagIsOn() {
        let stored = CapacityPreferences(confirmHandoffs: true, handoffDeadlineSeconds: 120)
        XCTAssertFalse(stored.handoffSettings.confirm)
        XCTAssertEqual(stored.handoffSettings.deadline, 120)
        XCTAssertTrue(stored.handoffSettings(confirmSurfaceExists: true).confirm,
                      "the stored flag is kept for when a confirm surface exists")
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
        ledger.configure(pools: AccountList(entries: accounts.map(AccountEntry.account)).effectivePools(),
                         accounts: accounts.map(CapacityPreferences.accountRef))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.05, at: Date()))
        XCTAssertEqual(ledger.latestReading(account: UsageRefs.workID)?.worstWindow?.utilization, 0.05)
        XCTAssertEqual(ledger.pool("claude-default")?.accounts, [UsageRefs.spareID])
        XCTAssertEqual(ledger.lease(pool: "claude-default")?.account.id, UsageRefs.spareID,
                       "the removed account has the most headroom and must still never be chosen")
    }
}
