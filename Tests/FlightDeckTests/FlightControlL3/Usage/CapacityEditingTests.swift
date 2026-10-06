import XCTest
import IntakeKit
@testable import FlightDeck

/// Every Settings edit is a pure function over `CapacityPreferences`, so the pane is a thin
/// binding and these pin the rules: default pools cannot be deleted, ids are minted once and
/// never reused for a different pool, thresholds can never cross, and the first edit of a
/// default pool stores it without losing what it held.
@MainActor
final class CapacityEditingTests: XCTestCase {
    private let accounts = [
        AgentAccount(id: UsageRefs.workID, agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/tmp/fd-edit/w")),
        AgentAccount(id: UsageRefs.spareID, agent: .claude, displayName: "Spare", home: URL(fileURLWithPath: "/tmp/fd-edit/s")),
    ]
    private func fixedUUIDs(_ texts: [String]) -> () -> UUID {
        var queue = texts.map { UUID(uuidString: $0)! }
        return { queue.removeFirst() }
    }

    func testNewIDsArePrefixedHexAndSkipTakenOnes() {
        let next = fixedUUIDs(["ABCDEF12-0000-0000-0000-000000000000", "12345678-0000-0000-0000-000000000000"])
        XCTAssertEqual(CapacityEditing.newPoolID(existing: ["pool-abcdef12"], random: next), "pool-12345678")
    }

    func testAddingAHostedPoolStoresTheDefaultsToo() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addHostedPool(&prefs, agent: .claude, accounts: accounts,
                                               random: fixedUUIDs(["ABCDEF12-0000-0000-0000-000000000000"]))
        XCTAssertEqual(id, "pool-abcdef12")
        XCTAssertEqual(prefs.pools?.map(\.id), ["claude-default", "pool-abcdef12"])
        XCTAssertEqual(prefs.pools?.last?.label, "New Claude pool")
        XCTAssertEqual(prefs.pools?.last?.accounts, [])
        XCTAssertEqual(prefs.pools?.first?.accounts, [UsageRefs.workID, UsageRefs.spareID])
    }

    func testAddingALocalPoolUsesTheDefaultCap() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addLocalPool(&prefs, harness: "opencode", accounts: accounts,
                                              random: fixedUUIDs(["0000AAAA-0000-0000-0000-000000000000"]))
        let pool = prefs.pools?.first { $0.id == id }
        XCTAssertEqual(pool?.kind, .local); XCTAssertEqual(pool?.concurrencyCap, 2); XCTAssertEqual(pool?.endpoint, "http://localhost:11434")
    }

    func testDefaultPoolsCannotBeRemovedUserPoolsCan() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addHostedPool(&prefs, agent: .claude, accounts: accounts)
        XCTAssertFalse(CapacityEditing.removePool("claude-default", &prefs, accounts: accounts))
        XCTAssertTrue(CapacityEditing.removePool(id, &prefs, accounts: accounts))
        XCTAssertEqual(prefs.pools?.map(\.id), ["claude-default"])
    }

    func testRenameTrimsAndIgnoresEmpty() {
        var prefs = CapacityPreferences()
        CapacityEditing.rename("claude-default", to: "  Day shift ", &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.first?.label, "Day shift")
        XCTAssertEqual(prefs.pools?.first?.id, "claude-default", "renaming never changes the id blocks store")
        CapacityEditing.rename("claude-default", to: "   ", &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.first?.label, "Day shift")
    }

    func testThresholdsNeverCross() {
        var prefs = CapacityPreferences()
        CapacityEditing.setThresholds("claude-default", soft: 0.97, hard: 0.95, &prefs, accounts: accounts)
        let p = prefs.pools?.first
        XCTAssertEqual(p?.hardThreshold ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(p?.softThreshold ?? 0, 0.90, accuracy: 1e-9)
        XCTAssertNoThrow(try p?.validate())
        CapacityEditing.setThresholds("claude-default", soft: 0.0, hard: 2.0, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.first?.softThreshold ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(prefs.pools?.first?.hardThreshold ?? 0, 1.0, accuracy: 1e-9)
    }

    func testToggleAndMoveAccounts() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addHostedPool(&prefs, agent: .claude, accounts: accounts)
        CapacityEditing.toggle(UsageRefs.workID, in: id, &prefs, accounts: accounts)
        CapacityEditing.toggle(UsageRefs.spareID, in: id, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.accounts, [UsageRefs.workID, UsageRefs.spareID])
        CapacityEditing.move(in: id, from: IndexSet(integer: 1), to: 0, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.accounts, [UsageRefs.spareID, UsageRefs.workID])
        CapacityEditing.toggle(UsageRefs.spareID, in: id, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.accounts, [UsageRefs.workID])
    }

    func testCapAndEndpointClamp() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addLocalPool(&prefs, harness: "opencode", accounts: accounts)
        CapacityEditing.setCap(id, 0, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.concurrencyCap, 1)
        CapacityEditing.setEndpoint(id, " http://box:11434 ", &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.endpoint, "http://box:11434")
    }

    func testNoLocalHarnessIsRegisteredOnMaster() {
        XCTAssertEqual(CapacityPane.defaultLocalHarnesses(), [], "claude and codex are both .login; OpenCode adds the first local one")
    }

    func testTheFixtureSeedsThreeAccountsAndTwoReadings() {
        let preferences = PreferencesStore(persistence: nil)
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        let usage = UsageService(environment: .live(store: store, preferences: preferences))
        UsageFixture.install(into: usage, preferences: preferences, now: Date())
        XCTAssertEqual(preferences.preferences.accounts.map(\.displayName), ["Work", "Spare", "Codex"],
                       "seeded accounts carry real email addresses; a screenshot must never show them")
        XCTAssertEqual(usage.ledger.headroom(pool: "claude-default").map(\.state), [.overSoft, .unknown])
        XCTAssertEqual(usage.ledger.headroom(pool: "codex-default").map(\.state), [.overHard])
    }

    func testAnotherAgentsAccountCannotJoinAPool() {
        let codex = AgentAccount(id: UsageRefs.codexID, agent: .codex, displayName: "Codex", home: URL(fileURLWithPath: "/tmp/fd-edit/c"))
        let all = accounts + [codex]
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addHostedPool(&prefs, agent: .claude, accounts: all)
        CapacityEditing.toggle(UsageRefs.codexID, in: id, &prefs, accounts: all)
        XCTAssertEqual(prefs.pools?.last?.accounts, [], "a codex account in a claude pool would be leased for a claude spawn")
        CapacityEditing.toggle(UUID(), in: id, &prefs, accounts: all)
        XCTAssertEqual(prefs.pools?.last?.accounts, [], "an unknown account cannot join either")
    }

    /// A default pool is every live account; Remove used to just reorder it while looking like
    /// an exclusion.
    func testTogglingAMemberOfADefaultPoolLeavesTheEffectivePoolUnchanged() {
        var prefs = CapacityPreferences()
        let before = prefs.effectivePools(accounts: accounts).first { $0.id == "claude-default" }?.accounts
        CapacityEditing.toggle(UsageRefs.workID, in: "claude-default", &prefs, accounts: accounts)
        let after = prefs.effectivePools(accounts: accounts).first { $0.id == "claude-default" }?.accounts
        XCTAssertEqual(after, before)
        XCTAssertEqual(after, [UsageRefs.workID, UsageRefs.spareID])
    }
}
