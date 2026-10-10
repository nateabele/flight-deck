import XCTest
import IntakeKit
@testable import FlightDeck

/// Unify brief R6/R8: Settings → Accounts is one ordered list of accounts and pools, pools hold
/// one agent's accounts one level deep, an account is in at most one pool, and the list is the
/// single source of truth for both accounts and the pools Flight Control leases from. These pin
/// the model's rules, the migration from the two stores it replaced, the downgrade mirror, and
/// how a project's pool assignment resolves.
@MainActor
final class AccountListTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/fd-account-list", isDirectory: true)
    private func account(_ name: String, _ agent: AgentID = .claude) -> AgentAccount {
        AgentAccount(agent: agent, displayName: name, home: root.appendingPathComponent(name))
    }

    private lazy var work = account("work")
    private lazy var spare = account("spare")
    private lazy var night = account("night")
    private lazy var codex = account("codex", .codex)

    // MARK: Migration

    func testMigrationNestsAUserPoolWhereItsFirstMemberWas() {
        let pool = CapacityPool.hosted(id: "pool-night001", label: "Night", agent: .claude, accounts: [night.id, spare.id])
        let list = AccountList.migrating(accounts: [work, codex, spare, night], pools: [pool])
        XCTAssertEqual(list.entries.map(\.id), [.account(work.id), .account(codex.id), .pool("pool-night001")])
        XCTAssertEqual(list.pool("pool-night001")?.members.map(\.id), [night.id, spare.id], "lease order is the pool's")
        XCTAssertEqual(list.accounts.map(\.id), [work.id, codex.id, night.id, spare.id])
    }

    func testMigrationCarriesEveryPoolSetting() throws {
        var stored = CapacityPool.hosted(id: "pool-night001", label: "Night", agent: .claude, accounts: [spare.id],
                                         soft: 0.6, hard: 0.85)
        stored.concurrencyCap = 5
        let pool = try XCTUnwrap(AccountList.migrating(accounts: [spare], pools: [stored]).pool("pool-night001"))
        XCTAssertEqual(pool.label, "Night")
        XCTAssertEqual(pool.agent, .claude)
        XCTAssertEqual(pool.kind, .hosted)
        XCTAssertEqual(pool.softThreshold, 0.6)
        XCTAssertEqual(pool.hardThreshold, 0.85)
        XCTAssertEqual(pool.concurrencyCap, 5)
    }

    /// Pools used to overlap. Now an account is in at most one: the first pool to name it keeps it.
    func testMigrationGivesAnOverlappingAccountToTheFirstPool() {
        let a = CapacityPool.hosted(id: "pool-a", label: "A", agent: .claude, accounts: [spare.id])
        let b = CapacityPool.hosted(id: "pool-b", label: "B", agent: .claude, accounts: [spare.id, night.id])
        let list = AccountList.migrating(accounts: [spare, night], pools: [a, b])
        XCTAssertEqual(list.pool("pool-a")?.members.map(\.id), [spare.id])
        XCTAssertEqual(list.pool("pool-b")?.members.map(\.id), [night.id])
        XCTAssertEqual(list.accounts.count, 2, "no account appears twice")
    }

    func testMigrationDropsAnotherAgentsMember() {
        let mixed = CapacityPool.hosted(id: "pool-mixed", label: "Mixed", agent: .claude, accounts: [codex.id, spare.id])
        let list = AccountList.migrating(accounts: [codex, spare], pools: [mixed])
        XCTAssertEqual(list.pool("pool-mixed")?.members.map(\.id), [spare.id])
        XCTAssertEqual(list.pool(containing: codex.id), nil, "the codex account stays at top level")
    }

    func testAnEmptyOrLocalPoolGoesAtTheEnd() {
        let local = CapacityPool.local(id: "pool-local001", label: "Ollama", agent: .claude, endpoint: "http://localhost:11434")
        let empty = CapacityPool.hosted(id: "pool-empty", label: "Empty", agent: .codex, accounts: [UUID()])
        let list = AccountList.migrating(accounts: [work], pools: [local, empty])
        XCTAssertEqual(list.entries.map(\.id), [.account(work.id), .pool("pool-local001"), .pool("pool-empty")])
        XCTAssertEqual(list.pool("pool-local001")?.kind, .local)
        XCTAssertEqual(list.pool("pool-local001")?.endpoint, "http://localhost:11434")
    }

    /// A default pool that only `materialize` ever stored is the synthesized default verbatim:
    /// nothing to keep, so it stays synthesized.
    func testAnUneditedStoredDefaultIsDropped() {
        let stored = CapacityPool.hosted(id: "claude-default", label: "Claude default", agent: .claude, accounts: [spare.id, work.id])
        let list = AccountList.migrating(accounts: [work, spare], pools: [stored])
        XCTAssertTrue(list.pools.isEmpty)
        XCTAssertEqual(list.effectivePools().first?.accounts, [work.id, spare.id], "lease order follows the list now")
    }

    /// An edited default keeps its settings as a memberless entry, so no account gets nested.
    func testAnEditedStoredDefaultKeepsItsSettingsWithoutNestingAnyone() throws {
        var stored = CapacityPool.hosted(id: "claude-default", label: "Claude default", agent: .claude, accounts: [work.id])
        stored.softThreshold = 0.7
        let list = AccountList.migrating(accounts: [work, spare], pools: [stored])
        XCTAssertEqual(list.pool("claude-default")?.members, [])
        XCTAssertEqual(list.entries.first?.id, .account(work.id))
        let effective = try XCTUnwrap(list.effectivePools().first { $0.id == "claude-default" })
        XCTAssertEqual(effective.softThreshold, 0.7)
        XCTAssertEqual(effective.accounts, [work.id, spare.id])
    }

    // MARK: Effective pools

    func testEveryAgentWithAnUnpooledAccountGetsASynthesizedDefault() {
        let list = AccountList(entries: [.account(work), .account(codex), .account(spare)])
        let pools = list.effectivePools()
        XCTAssertEqual(pools.map(\.id), ["claude-default", "codex-default"])
        XCTAssertEqual(pools[0].accounts, [work.id, spare.id])
        XCTAssertEqual(pools[0].label, "Claude default")
        XCTAssertEqual(pools[0].agent, .claude)
        XCTAssertEqual(pools[1].accounts, [codex.id])
    }

    /// The default holds the UNPOOLED accounts only — at most one pool per account — and still
    /// exists beside a user pool, so rules and blocks naming `claude-default` keep routing.
    func testAUserPoolTakesItsMembersOutOfTheDefault() {
        let list = AccountList(entries: [.account(work), .pool(AccountPool(id: "pool-n", label: "Night", agent: .claude, members: [night]))])
        let pools = list.effectivePools()
        XCTAssertEqual(pools.map(\.id), ["claude-default", "pool-n"])
        XCTAssertEqual(pools[0].accounts, [work.id])
        XCTAssertEqual(pools[1].accounts, [night.id])
    }

    func testAnAgentWhoseEveryAccountIsPooledHasNoDefault() {
        let list = AccountList(entries: [.pool(AccountPool(id: "pool-n", label: "Night", agent: .claude, members: [night]))])
        XCTAssertEqual(list.effectivePools().map(\.id), ["pool-n"])
    }

    func testATombstonedAccountIsNeverLeased() {
        var removed = spare
        removed.removedAt = Date()
        let list = AccountList(entries: [.account(work), .pool(AccountPool(id: "pool-n", label: "N", agent: .claude, members: [removed, night]))])
        XCTAssertEqual(list.effectivePools().first { $0.id == "pool-n" }?.accounts, [night.id])
    }

    // MARK: Rules

    func testAPoolRefusesAnotherAgentsAccount() throws {
        var list = AccountList(entries: [.account(codex), .pool(AccountPool(id: "pool-n", label: "N", agent: .claude))])
        XCTAssertThrowsError(try list.move(account: codex.id, toPool: "pool-n")) {
            XCTAssertEqual($0 as? AccountListError, .agentMismatch(account: .codex, pool: .claude))
        }
        XCTAssertThrowsError(try list.addPool(AccountPool(id: "pool-x", label: "X", agent: .claude, members: [codex])))
    }

    func testMovingAnAccountIntoAPoolTakesItOutOfWhereverItWas() throws {
        var list = AccountList(entries: [.account(work),
                                         .pool(AccountPool(id: "pool-a", label: "A", agent: .claude, members: [spare])),
                                         .pool(AccountPool(id: "pool-b", label: "B", agent: .claude))])
        try list.move(account: spare.id, toPool: "pool-b")
        try list.move(account: work.id, toPool: "pool-b", at: 0)
        XCTAssertEqual(list.pool("pool-a")?.members, [])
        XCTAssertEqual(list.pool("pool-b")?.members.map(\.id), [work.id, spare.id])
        XCTAssertEqual(list.accounts.count, 2)
        try list.move(account: work.id, toPool: nil, at: 0)
        XCTAssertEqual(list.entries.first?.id, .account(work.id))
    }

    func testRemovingAPoolKeepsItsAccountsWhereItWas() throws {
        var list = AccountList(entries: [.account(work), .pool(AccountPool(id: "pool-a", label: "A", agent: .claude, members: [spare, night])),
                                         .account(codex)])
        try list.removePool("pool-a")
        XCTAssertEqual(list.entries.map(\.id), [.account(work.id), .account(spare.id), .account(night.id), .account(codex.id)])
    }

    func testUpdatePoolChangesSettingsButNeverIdentityOrMembership() throws {
        var list = AccountList(entries: [.pool(AccountPool(id: "pool-a", label: "A", agent: .claude, members: [spare, night]))])
        try list.updatePool("pool-a") { pool in
            pool.label = "Renamed"
            pool.agent = .codex
            pool.id = "pool-z"
            pool.members.reverse()
        }
        let pool = try XCTUnwrap(list.pool("pool-a"))
        XCTAssertEqual(pool.label, "Renamed")
        XCTAssertEqual(pool.agent, .claude)
        XCTAssertEqual(pool.members.map(\.id), [night.id, spare.id], "a reorder is allowed")
        try list.updatePool("pool-a") { $0.members.append(self.codex) }
        XCTAssertEqual(list.pool("pool-a")?.members.map(\.id), [night.id, spare.id], "adding a member goes through move")
    }

    /// Unify brief R5: agy keeps its login in the keychain with no home variable, so gemini has
    /// exactly its built-in account.
    func testGeminiAcceptsOnlyItsBuiltInAccountOnce() throws {
        var list = AccountList()
        let builtIn = AgentAccount(agent: .gemini, displayName: "Default", home: AgentID.gemini.builtInHome)
        let other = AgentAccount(agent: .gemini, displayName: "Work", home: root.appendingPathComponent("gemini-work"))
        XCTAssertNotNil(list.addRefusal(for: other))
        XCTAssertNil(list.addRefusal(for: builtIn))
        try list.add(builtIn)
        XCTAssertThrowsError(try list.add(AgentAccount(agent: .gemini, displayName: "Again", home: AgentID.gemini.builtInHome))) {
            XCTAssertEqual($0 as? AccountListError, .addRefused(reason: AccountList.geminiRefusal))
        }
        XCTAssertNil(list.addRefusal(for: account("grok-work", .grok)), "grok binds GROK_HOME, so it has many")
    }

    func testPreferencesStoreRefusesASecondGeminiAccount() {
        let store = PreferencesStore(persistence: nil)
        let reason = store.addAccount(AgentAccount(agent: .gemini, displayName: "Work", home: root.appendingPathComponent("g")))
        XCTAssertEqual(reason, AccountList.geminiRefusal)
        XCTAssertNil(store.addAccount(work))
        XCTAssertTrue(store.preferences.accounts.contains { $0.id == work.id })
    }

    // MARK: The flat view

    /// Every pre-list caller writes `preferences.accounts` as a flat array. A rename, relocate or
    /// tombstone must keep the account in its pool; a new id lands at top level.
    func testWritingTheFlatArrayKeepsEachAccountInItsPool() {
        var list = AccountList(entries: [.account(work), .pool(AccountPool(id: "pool-a", label: "A", agent: .claude, members: [spare]))])
        var renamed = spare
        renamed.displayName = "Spare 2"
        list.accounts = [work, renamed, codex]
        XCTAssertEqual(list.pool("pool-a")?.members.map(\.displayName), ["Spare 2"])
        XCTAssertEqual(list.entries.last?.id, .account(codex.id))
        list.accounts = [codex]
        XCTAssertEqual(list.accounts.map(\.id), [codex.id])
        XCTAssertEqual(list.pool("pool-a")?.members, [], "removing an account removes it from its pool, not the pool")
    }

    func testPerAgentReorderStaysInsideEachContainer() {
        var prefs = Preferences()
        prefs.accountList = AccountList(entries: [.account(work), .account(codex), .account(spare),
                                                  .pool(AccountPool(id: "pool-a", label: "A", agent: .claude, members: [night]))])
        prefs.moveAccounts(forAgent: .claude, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(prefs.accountList.entries.map(\.id),
                       [.account(spare.id), .account(codex.id), .account(work.id), .pool("pool-a")])
    }

    // MARK: Preferences: migration, mirror, decoding

    func testAPreListBlobMigratesOnLoadAndIsWrittenBack() throws {
        let persistence = PreferencesStoreTests.MemoryPersistence()
        let pool = CapacityPool.hosted(id: "pool-night001", label: "Night", agent: .claude, accounts: [spare.id])
        persistence.stored = Preferences(storedAccounts: [work, spare, codex], capacity: CapacityPreferences(pools: [pool]))

        let store = PreferencesStore(persistence: persistence)

        XCTAssertEqual(store.preferences.accountList.pool("pool-night001")?.members.map(\.id), [spare.id])
        XCTAssertEqual(store.effectivePools.map(\.id), ["claude-default", "codex-default", "pool-night001"])
        XCTAssertNotNil(persistence.stored?.storedAccountList, "the migrated list reaches disk on the launch that made it")
    }

    /// An older build installed over this one reads `storedAccounts` and `capacity.pools`. They
    /// are kept in step, minus agents an older build cannot decode.
    func testEveryWriteRefreshesTheLegacyMirror() {
        var prefs = Preferences()
        let grok = account("grok", .grok)
        prefs.accountList = AccountList(entries: [.account(work), .account(grok),
                                                  .pool(AccountPool(id: "pool-a", label: "A", agent: .claude, members: [spare])),
                                                  .pool(AccountPool(id: "pool-g", label: "G", agent: .grok))])
        XCTAssertEqual(prefs.storedAccounts?.map(\.id), [work.id, spare.id])
        XCTAssertEqual(prefs.capacity?.pools?.map(\.id), ["pool-a"])
        XCTAssertEqual(prefs.capacity?.pools?.first?.accounts, [spare.id])
    }

    func testTheListRoundTripsAndSkipsAnUnreadableEntry() throws {
        let list = AccountList(entries: [.account(work), .pool(AccountPool(id: "pool-a", label: "A", agent: .codex, members: [codex]))])
        let data = try JSONEncoder().encode(list)
        XCTAssertEqual(try JSONDecoder().decode(AccountList.self, from: data), list)

        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try XCTUnwrap(raw["entries"] as? [Any])
        entries.append(["account": ["id": UUID().uuidString, "agent": "aider", "displayName": "X", "home": "file:///tmp/x/"]])
        raw["entries"] = entries
        let decoded = try JSONDecoder().decode(AccountList.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(decoded, list, "an entry a newer build wrote costs that entry, not every preference")
    }

    // MARK: Project assignment (R8)

    func testAPoolAssignmentResolvesToItsFirstLiveAccount() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [.account(work),
                                                              .pool(AccountPool(id: "pool-n", label: "N", agent: .claude, members: [night, spare]))])
        store.setProjectSettings("/p", ProjectSettings(accounts: [.claude: .pool("pool-n")]))
        XCTAssertEqual(store.account(for: .claude, project: "/p")?.id, night.id)
        store.markAccountRemoved(id: night.id)
        XCTAssertEqual(store.account(for: .claude, project: "/p")?.id, spare.id, "a removed member is skipped")
    }

    func testAPoolAssignmentWithNothingToLeaseIsBroken() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [.account(work), .pool(AccountPool(id: "pool-n", label: "N", agent: .claude))])
        store.setProjectSettings("/p", ProjectSettings(accounts: [.claude: .pool("pool-n")]))
        XCTAssertNil(store.account(for: .claude, project: "/p"),
                     "an empty pool must not fall back to another login")
        store.setProjectSettings("/p", ProjectSettings(accounts: [.claude: .pool("pool-gone")]))
        XCTAssertNil(store.account(for: .claude, project: "/p"))
    }

    func testRemovingAPoolClearsTheProjectsThatNamedIt() throws {
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [.pool(AccountPool(id: "pool-n", label: "N", agent: .claude, members: [night]))])
        store.setProjectSettings("/p", ProjectSettings(accounts: [.claude: .pool("pool-n"), .codex: .account(codex.id)]))
        try store.removePool("pool-n")
        XCTAssertNil(store.projectSettings("/p").accounts[.claude])
        XCTAssertEqual(store.projectSettings("/p").accounts[.codex], .account(codex.id))
        XCTAssertTrue(store.preferences.accounts.contains { $0.id == night.id }, "its account is kept")
    }
}
