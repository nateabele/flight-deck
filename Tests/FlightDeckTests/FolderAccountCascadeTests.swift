import FleetKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// A folder's account assignment cascades to every path beneath it that sets none: the
/// resolution order, the removal paths that must reach folder records, what leasing and
/// `/switch-account` make of an inherited pool, and how the Projects picker names the choice.
@MainActor
final class FolderAccountCascadeTests: XCTestCase {
    private let field = "/tmp/fd-cascade/Field"
    private let app = "/tmp/fd-cascade/Field/orchard-app"
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
        let root = URL(fileURLWithPath: "/tmp/fd-cascade-homes", isDirectory: true)
        a = AgentAccount(agent: .claude, displayName: "A", home: root.appendingPathComponent("a"))
        b = AgentAccount(agent: .claude, displayName: "B", home: root.appendingPathComponent("b"))
        c = AgentAccount(agent: .claude, displayName: "C", home: root.appendingPathComponent("c"))
        x = AgentAccount(agent: .codex, displayName: "X", home: root.appendingPathComponent("x"))
        store.preferences.accountList = AccountList(entries: [
            .account(c),
            .account(x),
            .pool(AccountPool(id: team, label: "Team", agent: .claude, members: [a, b])),
        ])
        ledger.configure(pools: store.effectivePools,
                         accounts: store.preferences.accounts.map(CapacityPreferences.accountRef))
    }

    private func resolver() -> AccountResolver { AccountResolver(preferences: store, ledger: ledger) }

    private func assign(_ assignment: AccountAssignment?, at path: String, agent: AgentID = .claude) {
        var settings = store.projectSettings(path)
        settings.accounts[agent] = assignment
        store.setProjectSettings(path, settings)
    }

    private func read(_ account: AgentAccount, _ utilization: Double) {
        ledger.ingest(UsageReading(account: CapacityPreferences.accountRef(account),
                                   windows: [UsageWindow(name: "5h", utilization: utilization, resetsAt: nil)],
                                   readAt: now, source: "test", hardRejection: false))
    }

    // MARK: Resolution

    func testTheNearestAssignmentWins() {
        assign(.account(a.id), at: "/tmp/fd-cascade")
        assign(.account(b.id), at: field)
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: app), .account(b.id), "nearest ancestor")
        assign(.account(c.id), at: app)
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: app), .account(c.id), "its own beats any ancestor")
        assign(nil, at: field)
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: "\(field)/other"), .account(a.id),
                       "a farther ancestor when the nearer sets none")
    }

    func testTheAgentDefaultThenTheTopmostComeAfterEveryAncestor() {
        XCTAssertNil(store.effectiveAssignment(for: .claude, project: app), "topmost")
        store.setAccountDefault(.account(b.id), for: .claude)
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: app), .account(b.id), "agent default")
        assign(.account(a.id), at: field)
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: app), .account(a.id), "ancestor beats default")
    }

    func testAgentsInheritIndependently() {
        assign(.account(a.id), at: field)
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: app), .account(a.id))
        XCTAssertNil(store.effectiveAssignment(for: .codex, project: app))
        assign(.account(x.id), at: app, agent: .codex)
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: app), .account(a.id))
    }

    func testAncestryIsByPathComponent() {
        assign(.account(a.id), at: "/tmp/fd-cascade/foo")
        XCTAssertNil(store.effectiveAssignment(for: .claude, project: "/tmp/fd-cascade/foobar"))
        XCTAssertNil(store.inheritedAssignment(for: .claude, project: "/tmp/fd-cascade/foobar"))
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: "/tmp/fd-cascade/foo/bar"), .account(a.id))
    }

    func testAPathIsNotItsOwnAncestor() {
        assign(.account(a.id), at: field)
        XCTAssertNil(store.inheritedAssignment(for: .claude, project: field))
    }

    func testPathsAreStandardizedOnBothSides() {
        assign(.account(a.id), at: "\(field)/")
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: "\(field)/./sub/../orchard-app/"), .account(a.id))
        let inherited = store.inheritedAssignment(for: .claude, project: app)
        XCTAssertEqual(inherited?.source, field, "the source is the folder's standardized key")
        XCTAssertEqual(inherited?.assignment, .account(a.id))
    }

    func testAWorktreeUnderAProjectInheritsTheProjectsAssignment() {
        assign(.account(a.id), at: field)
        assign(.account(b.id), at: app)
        XCTAssertEqual(store.effectiveAssignment(for: .claude, project: "\(app)/.claude/worktrees/wt1"), .account(b.id))
        XCTAssertEqual(store.account(for: .claude, project: "\(field)/larkOS/.claude/worktrees/wt2")?.id, a.id)
    }

    func testOnlyTheAccountAssignmentCascades() {
        var folder = ProjectSettings(defaultAgent: .codex, accounts: [.claude: .account(a.id)],
                                     options: [.codex: .codex(CodexThreadOptions())])
        folder.flywheelEnabled = true
        folder.drawerCollapsed = true
        store.setProjectSettings(field, folder)
        let child = store.projectSettings(app)
        XCTAssertNil(child.defaultAgent)
        XCTAssertTrue(child.options.isEmpty)
        XCTAssertNil(child.flywheelEnabled)
        XCTAssertNil(child.drawerCollapsed)
    }

    func testAStaleInheritedAssignmentIsBrokenNotSilentlyAnotherLogin() {
        assign(.account(a.id), at: field)
        store.preferences.accountList.accounts = store.preferences.accounts.map {
            var copy = $0
            if copy.id == a.id { copy.removedAt = now }
            return copy
        }
        XCTAssertNil(store.account(for: .claude, project: app))
    }

    // MARK: Invalidation

    func testRemovingAnAccountClearsFolderEntriesToo() {
        assign(.account(a.id), at: field)
        assign(.account(c.id), at: "/tmp/fd-cascade/Other")
        store.markAccountRemoved(id: a.id)
        XCTAssertNil(store.preferences.projectSettings[field], "an emptied folder record is dropped")
        XCTAssertNil(store.effectiveAssignment(for: .claude, project: app))
        XCTAssertEqual(store.projectSettings("/tmp/fd-cascade/Other").accounts[.claude], .account(c.id))
    }

    func testDeletingAPoolClearsFolderEntriesToo() throws {
        assign(.pool(team), at: field)
        try store.removePool(team)
        XCTAssertNil(store.preferences.projectSettings[field])
        XCTAssertNil(store.effectiveAssignment(for: .claude, project: app))
    }

    // MARK: Leasing

    func testAProjectLeasesFromAPoolItsFolderNames() throws {
        assign(.pool(team), at: field)
        read(a, 0.90)
        read(b, 0.10)
        let r = try resolver().resolve(agent: .claude, project: app).get()
        XCTAssertEqual(r.account?.id, b.id)
        XCTAssertEqual(r.source, .pool(team))
        XCTAssertEqual(ledger.activeLeases(pool: team), [try XCTUnwrap(r.lease)])
    }

    func testThawRollsOverWithinAnInheritedPool() {
        assign(.pool(team), at: field)
        read(a, 0.99)
        read(b, 0.10)
        let plan = resolver().thawPlan(agent: .claude, project: app, account: a, blocked: nil)
        guard case .rollOver(let to, let resolution) = plan else { return XCTFail("expected a rollover, got \(plan)") }
        XCTAssertEqual(to.id, b.id)
        resolver().release(resolution)
    }

    func testReacquireLeasesInAnInheritedPool() {
        assign(.pool(team), at: field)
        let resolver = resolver()
        let tab = UUID()
        XCTAssertTrue(resolver.reacquire(agent: .claude, project: app, account: a, for: tab))
        XCTAssertEqual(resolver.leases(heldBy: tab).map(\.account.id), [a.id])
        XCTAssertFalse(resolver.reacquire(agent: .claude, project: app, account: c, for: UUID()))
    }

    func testSwitchAccountMarksAnInheritedPoolAssigned() {
        let resolver = resolver()
        XCTAssertEqual(resolver.choices(agent: .claude, project: app, current: a).pools.map(\.isAssigned), [false])
        assign(.pool(team), at: field)
        XCTAssertEqual(resolver.choices(agent: .claude, project: app, current: a).pools.map(\.isAssigned), [true])
        assign(.account(c.id), at: app)
        XCTAssertEqual(resolver.choices(agent: .claude, project: app, current: a).pools.map(\.isAssigned), [false])
    }

    // MARK: Picker

    func testTheUnsetRowNamesTheFolderItInheritsFrom() {
        let list = store.preferences.accountList
        let pool = ProjectsSettingsTab.accountOptions(for: .claude, in: list, inherited: (.pool(team), field))
        XCTAssertEqual(pool[0].title, "Inherit from Field (Team pool)")
        XCTAssertNil(pool[0].value, "choosing it clears the override")
        let account = ProjectsSettingsTab.accountOptions(for: .claude, in: list, inherited: (.account(b.id), field))
        XCTAssertEqual(account[0].title, "Inherit from Field (B)")
    }

    func testTheUnsetRowIsTheDefaultWhenNothingIsInherited() {
        let list = store.preferences.accountList
        XCTAssertEqual(ProjectsSettingsTab.accountOptions(for: .claude, in: list, agentDefault: .account(b.id))[0].title,
                       "Default (B)")
        XCTAssertEqual(ProjectsSettingsTab.accountOptions(for: .claude, in: list, inherited: nil)[0].title, "Default (C)")
    }

    func testAnInheritedAssignmentThatNamesNothingLiveStillNamesTheFolder() {
        let list = store.preferences.accountList
        XCTAssertEqual(ProjectsSettingsTab.accountOptions(for: .claude, in: list, inherited: (.pool("gone"), field))[0].title,
                       "Inherit from Field")
    }

    func testThePickerShowsForAnInheritedChoice() {
        let one = AccountList(entries: [.account(c)])
        XCTAssertFalse(ProjectsSettingsTab.showsAccountPicker(for: .claude, in: one, assigned: nil))
        XCTAssertTrue(ProjectsSettingsTab.showsAccountPicker(for: .claude, in: one, assigned: .pool("gone")))
    }

    // MARK: Storage

    func testFolderAssignmentsRoundTripThroughPreferences() throws {
        assign(.pool(team), at: field)
        assign(.account(c.id), at: app)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(store.preferences))
        let restored = PreferencesStore(persistence: nil)
        restored.preferences = decoded
        XCTAssertEqual(restored.effectiveAssignment(for: .claude, project: "\(field)/larkOS"), .pool(team))
        XCTAssertEqual(restored.effectiveAssignment(for: .claude, project: app), .account(c.id))
    }
}
