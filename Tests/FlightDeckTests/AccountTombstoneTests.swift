import XCTest
@testable import FlightDeck

/// Removal is a soft delete. The rules split cleanly in two and this suite pins both halves:
/// a tombstoned account still resolves BY ID (so a live tab's runtime key never moves), and
/// is absent from every LIST and default (so nothing offers it).
@MainActor
final class AccountTombstoneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func home(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    /// A store holding the built-in claude account plus one ordinary one.
    private func makeStore() -> (PreferencesStore, AgentAccount, AgentAccount) {
        let store = PreferencesStore(persistence: nil)
        let builtIn = AgentAccount(
            agent: .claude, displayName: "Default", home: AgentID.claude.builtInHome
        )
        let work = AgentAccount(agent: .claude, displayName: "Work", home: home("work"))
        store.preferences.storedAccounts = [builtIn, work]
        return (store, builtIn, work)
    }

    /// The invariant the whole design exists for. A tab running as this account keys its
    /// watchers and its codex stack on the resolved id; if removal moved that key, the
    /// existing watchers would be unmatchable and the next lookup would build a SECOND codex
    /// app-server at the nil key, pointed at the wrong home.
    func testATombstonedAccountStillResolvesByID() {
        let (store, _, work) = makeStore()
        store.markAccountRemoved(id: work.id)
        XCTAssertEqual(store.account(id: work.id)?.id, work.id)
        XCTAssertEqual(store.resolvedAccountID(for: .claude, in: work.id), work.id)
    }

    /// A genuinely unknown id still resolves to nothing — the tombstone must not turn every
    /// dangling reference into a live one.
    func testAnUnknownIDStillResolvesToNothing() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.resolvedAccountID(for: .claude, in: UUID()))
    }

    func testATombstonedAccountLeavesEveryListAndDefault() {
        let (store, builtIn, work) = makeStore()
        store.markAccountRemoved(id: builtIn.id)
        XCTAssertEqual(store.preferences.accounts(for: .claude).map(\.id), [work.id])
        XCTAssertEqual(store.preferences.liveAccounts.map(\.id), [work.id])
        // The topmost fallback for a project that has chosen nothing.
        XCTAssertEqual(store.account(for: .claude, project: root.path)?.id, work.id)
        // But a nil `Session.accountID` is NOT one of those defaults — it is the identity of
        // every tab persisted before accounts existed, so it keeps resolving to the built-in
        // account tombstone and all. This assertion used to read `nil`, which pinned the hole
        // in the tombstone: nil there moves such a tab's `instance(for:)` key off `builtIn.id`
        // mid-run while both keys still name `~/.claude`, stranding its watchers and putting a
        // second `codex app-server` on one `session_index.jsonl`.
        XCTAssertEqual(store.resolvedAccountID(for: .claude, in: nil), builtIn.id)
    }

    /// A tombstone still holds its home, and this assertion used to read the other way round —
    /// "the user removed it, so its home is theirs to re-use". Re-adding the same directory
    /// while the tombstone is standing files a SECOND record, with a new id, for one home:
    /// the tombstone keys the tabs still running as the removed account, the new record keys
    /// every new tab, and both name the same `session_index.jsonl`. That is the two-accounts-
    /// one-home collision `AddAccountSheet` refuses for. The launch purge is what releases it.
    func testATombstonedAccountStillHoldsItsHome() {
        let (store, _, work) = makeStore()
        XCTAssertTrue(store.homeIsTaken(work.home, excluding: nil))
        store.markAccountRemoved(id: work.id)
        XCTAssertTrue(store.homeIsTaken(work.home, excluding: nil))
        XCTAssertEqual(
            AccountDraft.validate(home: work.home.path, agent: .claude, editing: nil, in: store),
            .homeAlreadyUsed,
            "and the sheet refuses it, rather than filing a second record for one home"
        )
        // Its own relocate still is not a collision with itself, tombstoned or not.
        XCTAssertFalse(store.homeIsTaken(work.home, excluding: work.id))
    }

    /// The wording the user actually reads has to hold for the case they will actually hit:
    /// they removed the account seconds ago, so "another account already uses this location"
    /// would be a flat falsehood. It says what is true instead — the location comes back on
    /// the next start.
    func testTheHomeInUseMessageAdmitsARemovedAccountIsHoldingIt() throws {
        let message = try XCTUnwrap(AccountDraft.Validation.homeAlreadyUsed.message(for: .claude))
        XCTAssertTrue(message.contains("removed"), message)
        XCTAssertTrue(message.contains("starts"), message)
    }

    /// Unchanged from hard delete: nothing may be left pointing at an account the user removed.
    func testRemovalStillClearsProjectAssignments() {
        let (store, _, work) = makeStore()
        store.setProjectSettings(root.path, ProjectSettings(accounts: [.claude: work.id]))
        store.markAccountRemoved(id: work.id)
        XCTAssertNil(store.projectSettings(root.path).accounts[.claude])
    }

    /// Reordering writes a reordered live list back into the slots the live accounts hold. If
    /// it wrote into every slot for the agent, a tombstone in the middle would swallow one
    /// entry and shift the rest.
    func testReorderingSkipsTombstonedSlots() {
        let store = PreferencesStore(persistence: nil)
        let a = AgentAccount(agent: .claude, displayName: "A", home: home("a"))
        let dead = AgentAccount(agent: .claude, displayName: "Dead", home: home("dead"))
        let b = AgentAccount(agent: .claude, displayName: "B", home: home("b"))
        store.preferences.storedAccounts = [a, dead, b]
        store.markAccountRemoved(id: dead.id)
        store.preferences.moveAccounts(forAgent: .claude, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(store.preferences.accounts(for: .claude).map(\.displayName), ["B", "A"])
    }

    /// Tombstones exist only to protect live tabs, and at launch there are none.
    func testTombstonesArePurgedAtLaunch() {
        var preferences = Preferences()
        let live = AgentAccount(agent: .claude, displayName: "Live", home: home("live"))
        var dead = AgentAccount(agent: .claude, displayName: "Dead", home: home("dead"))
        dead.removedAt = Date()
        preferences.storedAccounts = [live, dead]
        preferences.purgeRemovedAccounts()
        XCTAssertEqual(preferences.accounts.map(\.id), [live.id])
    }

    /// Existing stored JSON has no `removedAt` key. Decoding must treat that as live, not fail.
    func testAccountsStoredBeforeTombstonesDecodeAsLive() throws {
        let json = Data("""
        [{"id":"\(UUID().uuidString)","agent":"claude","displayName":"W","home":"file:///tmp/w"}]
        """.utf8)
        let decoded = try JSONDecoder().decode([AgentAccount].self, from: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].removedAt)
        XCTAssertFalse(decoded[0].isRemoved)
    }

    /// Both "New … Session" menus call `NewSessionAffordance.menu(agents:preferences:resolved:)`,
    /// which does the live-account filtering itself — this drives that overload with a
    /// `Preferences` holding a tombstone, the same shape either call site passes, so it fails if
    /// the overload (or a future third call site) ever reverts to the raw `accounts` array.
    /// Two live accounts nest into a submenu; tombstoning one drops the agent back to a single
    /// flat row — and `NewSessionAffordance.chords` moves the agent's chord onto it, so no
    /// shortcut is lost.
    func testTombstonedAccountsLeaveTheNewSessionMenus() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "Work", home: home("work"))
        let personal = AgentAccount(agent: .claude, displayName: "Personal", home: home("personal"))
        store.preferences.storedAccounts = [work, personal]
        let agents = [AgentSettings(id: .claude, options: .claude(FlagSet()))]

        let before = NewSessionAffordance.menu(
            agents: agents, preferences: store.preferences,
            resolved: [.claude: work.id]
        )
        guard case .submenu(_, let rows) = before.first else {
            return XCTFail("two live accounts should nest, got \(String(describing: before.first))")
        }
        XCTAssertEqual(rows.count, 2)

        store.markAccountRemoved(id: personal.id)
        let after = NewSessionAffordance.menu(
            agents: agents, preferences: store.preferences,
            resolved: [.claude: work.id]
        )
        XCTAssertEqual(after, [.agent(.claude, account: work.id, isResolved: true)])
        XCTAssertEqual(NewSessionAffordance.chords(for: after, agents: agents)[work.id], [.command])
    }
}
