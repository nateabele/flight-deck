import XCTest
import IntakeKit
@testable import FlightDeck

/// Every pool edit is a pure function over the Accounts list (unify brief R6), so the pane is a
/// thin binding and these pin the rules: synthesized default pools cannot be deleted, ids are
/// minted once and never reused for a different pool, thresholds can never cross, editing a
/// default stores its settings without nesting anyone's accounts, and a pool holds one agent's
/// accounts, each in at most one pool.
@MainActor
final class CapacityEditingTests: XCTestCase {
    private let accounts = [
        AgentAccount(id: UsageRefs.workID, agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/tmp/fd-edit/w")),
        AgentAccount(id: UsageRefs.spareID, agent: .claude, displayName: "Spare", home: URL(fileURLWithPath: "/tmp/fd-edit/s")),
    ]
    private var list: AccountList { AccountList(entries: accounts.map(AccountEntry.account)) }
    private func fixedUUIDs(_ texts: [String]) -> () -> UUID {
        var queue = texts.map { UUID(uuidString: $0)! }
        return { queue.removeFirst() }
    }
    private func effective(_ list: AccountList, _ id: PoolID) -> CapacityPool? { list.effectivePools().first { $0.id == id } }

    func testNewIDsArePrefixedHexAndSkipTakenOnes() {
        let next = fixedUUIDs(["ABCDEF12-0000-0000-0000-000000000000", "12345678-0000-0000-0000-000000000000"])
        XCTAssertEqual(CapacityEditing.newPoolID(existing: ["pool-abcdef12"], random: next), "pool-12345678")
    }

    func testAddingAHostedPoolLeavesTheDefaultSynthesized() {
        var list = list
        let id = CapacityEditing.addHostedPool(&list, agent: .claude, random: fixedUUIDs(["ABCDEF12-0000-0000-0000-000000000000"]))
        XCTAssertEqual(id, "pool-abcdef12")
        XCTAssertEqual(list.pools.map(\.id), ["pool-abcdef12"], "the default is derived, never stored by an unrelated edit")
        XCTAssertEqual(list.pool(id)?.label, "New Claude pool")
        XCTAssertEqual(list.pool(id)?.members, [])
        XCTAssertEqual(list.effectivePools().map(\.id), ["claude-default", "pool-abcdef12"])
        XCTAssertEqual(effective(list, "claude-default")?.accounts, [UsageRefs.workID, UsageRefs.spareID])
    }

    func testAddingALocalPoolUsesTheDefaultCap() {
        var list = list
        let id = CapacityEditing.addLocalPool(&list, agent: .gemini, random: fixedUUIDs(["0000AAAA-0000-0000-0000-000000000000"]))
        let pool = list.pool(id)
        XCTAssertEqual(pool?.kind, .local); XCTAssertEqual(pool?.concurrencyCap, 2); XCTAssertEqual(pool?.endpoint, "http://localhost:11434")
    }

    func testSynthesizedDefaultPoolsCannotBeRemovedUserPoolsCan() {
        var list = list
        let id = CapacityEditing.addHostedPool(&list, agent: .claude)
        XCTAssertFalse(CapacityEditing.removePool("claude-default", &list))
        XCTAssertTrue(CapacityEditing.removePool(id, &list))
        XCTAssertEqual(list.effectivePools().map(\.id), ["claude-default"])
    }

    /// Editing a default stores its settings as a memberless entry: the accounts stay at top
    /// level and still fill it.
    func testRenamingADefaultStoresItWithoutNestingAccounts() {
        var list = list
        CapacityEditing.rename("claude-default", to: "  Day shift ", &list)
        XCTAssertEqual(effective(list, "claude-default")?.label, "Day shift")
        XCTAssertEqual(list.pool("claude-default")?.members, [])
        XCTAssertEqual(effective(list, "claude-default")?.accounts, [UsageRefs.workID, UsageRefs.spareID])
        XCTAssertEqual(list.entries.first?.id, .account(UsageRefs.workID))
        CapacityEditing.rename("claude-default", to: "   ", &list)
        XCTAssertEqual(effective(list, "claude-default")?.label, "Day shift")
    }

    func testThresholdsNeverCross() {
        var list = list
        CapacityEditing.setThresholds("claude-default", soft: 0.97, hard: 0.95, &list)
        let p = effective(list, "claude-default")
        XCTAssertEqual(p?.hardThreshold ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(p?.softThreshold ?? 0, 0.90, accuracy: 1e-9)
        XCTAssertNoThrow(try p?.validate())
        CapacityEditing.setThresholds("claude-default", soft: 0.0, hard: 2.0, &list)
        XCTAssertEqual(effective(list, "claude-default")?.softThreshold ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(effective(list, "claude-default")?.hardThreshold ?? 0, 1.0, accuracy: 1e-9)
    }

    func testToggleAndMoveAccounts() {
        var list = list
        let id = CapacityEditing.addHostedPool(&list, agent: .claude)
        CapacityEditing.toggle(UsageRefs.workID, in: id, &list)
        CapacityEditing.toggle(UsageRefs.spareID, in: id, &list)
        XCTAssertEqual(effective(list, id)?.accounts, [UsageRefs.workID, UsageRefs.spareID])
        XCTAssertNil(effective(list, "claude-default"), "every claude account is pooled now, so there is no default")
        CapacityEditing.move(in: id, from: IndexSet(integer: 1), to: 0, &list)
        XCTAssertEqual(effective(list, id)?.accounts, [UsageRefs.spareID, UsageRefs.workID])
        CapacityEditing.toggle(UsageRefs.spareID, in: id, &list)
        XCTAssertEqual(effective(list, id)?.accounts, [UsageRefs.workID])
        XCTAssertEqual(effective(list, "claude-default")?.accounts, [UsageRefs.spareID], "back at top level, back in the default")
    }

    /// An account is in at most one pool: putting it in a second takes it out of the first.
    func testTogglingIntoASecondPoolMovesTheAccount() {
        var list = list
        let a = CapacityEditing.addHostedPool(&list, agent: .claude)
        let b = CapacityEditing.addHostedPool(&list, agent: .claude)
        CapacityEditing.toggle(UsageRefs.workID, in: a, &list)
        CapacityEditing.toggle(UsageRefs.workID, in: b, &list)
        XCTAssertEqual(effective(list, a)?.accounts, [])
        XCTAssertEqual(effective(list, b)?.accounts, [UsageRefs.workID])
    }

    func testCapAndEndpointClamp() {
        var list = list
        let id = CapacityEditing.addLocalPool(&list, agent: .gemini)
        CapacityEditing.setCap(id, 0, &list)
        XCTAssertEqual(list.pool(id)?.concurrencyCap, 1)
        CapacityEditing.setEndpoint(id, " http://box:11434 ", &list)
        XCTAssertEqual(list.pool(id)?.endpoint, "http://box:11434")
    }

    func testNoLocalAgentIsRegisteredOnMaster() {
        XCTAssertEqual(CapacityPane.defaultLocalAgents(), [], "claude and codex are both .login; a local provider adds the first")
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
        var list = AccountList(entries: (accounts + [codex]).map(AccountEntry.account))
        let id = CapacityEditing.addHostedPool(&list, agent: .claude)
        CapacityEditing.toggle(UsageRefs.codexID, in: id, &list)
        XCTAssertEqual(list.pool(id)?.members, [], "a codex account in a claude pool would be leased for a claude spawn")
        CapacityEditing.toggle(UUID(), in: id, &list)
        XCTAssertEqual(list.pool(id)?.members, [], "an unknown account cannot join either")
    }

    /// A default pool is every unpooled account of its agent; Remove used to just reorder it while
    /// looking like an exclusion.
    func testTogglingAMemberOfADefaultPoolLeavesTheEffectivePoolUnchanged() {
        var list = list
        CapacityEditing.rename("claude-default", to: "Stored default", &list)
        let before = effective(list, "claude-default")?.accounts
        CapacityEditing.toggle(UsageRefs.workID, in: "claude-default", &list)
        let after = effective(list, "claude-default")?.accounts
        XCTAssertEqual(after, before)
        XCTAssertEqual(after, [UsageRefs.workID, UsageRefs.spareID])
    }
}
