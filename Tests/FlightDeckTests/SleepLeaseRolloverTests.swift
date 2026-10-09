import XCTest
import IntakeKit
@testable import FlightDeck

/// Smart sleep and the pool lease (round 2, sleep-lease-rollover). Nate's rules:
/// 1. freezing an agent releases its lease at once;
/// 2. thawing re-leases the SAME account, even past soft or the pool's cap;
/// 3. unless that account is spent — then an idle conversation moves to another member of the
///    pool, same tab, same conversation id, draft carried;
/// 4. with no other member to move to, it thaws in place and the user is told.
@MainActor
final class SleepLeaseRolloverTests: XCTestCase {
    // MARK: Fixture

    private final class Daemons: DaemonControlling {
        var stopped: [UUID] = [], conted: [UUID] = [], terminated: [UUID] = []
        func isLive(_ id: UUID) -> Bool { false }
        func isLive(socketPath: String) -> Bool { false }
        /// Beyond any real pid, so the sleep controller's process walk finds no descendants.
        func daemonPID(_ id: UUID) -> pid_t? { 99_999_999 }
        func daemonPID(socketPath: String) -> pid_t? { nil }
        func terminate(_ id: UUID) { terminated.append(id) }
        func terminate(socketPath: String) {}
        func peerPID(socketPath: String) -> pid_t? { nil }
        func terminate(pid: pid_t, socketPath: String) {}
        func stop(_ id: UUID) { stopped.append(id) }
        func cont(_ id: UUID) { conted.append(id) }
    }

    private final class Notices: Notifying {
        var posted: [(id: UUID, title: String, body: String)] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, subtitle: String, body: String) { posted.append((sessionID, title, body)) }
        func withdraw(sessionID: UUID) {}
    }

    private final class Provider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { configs.append(config); return nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private final class Reporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// A claude screen: rule, composer row, rule. Records what is pasted into it.
    private final class Composer: TextInjecting {
        var row: String
        var pasted: [String] = []
        init(_ row: String) { self.row = row }
        func sendText(_ text: String) { pasted.append(text) }
        func sendReturn() {}
        func sendKillLine() {}
        func sendYank() {}
        func sendArrowDown() {}
        func sendArrowUp() {}
        func sendTab() {}
        func sendEscape() {}
        func sendCharacterKey(_ character: Character) {}
        func sendControlKey(_ letter: Character) {}
        func readViewport() -> String? {
            let rule = String(repeating: "─", count: 40)
            return [rule, row, rule, "  ? for shortcuts"].joined(separator: "\n")
        }
    }

    private var suite: URL!
    private var retained: [AnyObject] = []

    override func setUpWithError() throws {
        suite = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: suite)
        retained.removeAll()
    }

    private func dir(_ name: String) -> URL {
        let url = suite.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Rig {
        let store: SessionStore
        let ledger: CapacityLedger
        let first: AgentAccount
        let second: AgentAccount
        let daemons: Daemons
        let notices: Notices
        let provider: Provider
        let tab: Session
    }

    /// A project on a two-member claude pool, a tab on `first`, and a second tab selected so the
    /// first can sleep (a selected tab never does). Sleep fires on the first eligible tick.
    private func rig(agent: AgentID = .claude) -> Rig {
        let first = AgentAccount(agent: agent, displayName: "First", home: dir("first"))
        let second = AgentAccount(agent: agent, displayName: "Second", home: dir("second"))
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.accountList = AccountList(entries: [
            .pool(AccountPool(id: "team", label: "Team", agent: agent, members: [first, second])),
        ])
        let project = dir("project")
        preferences.preferences.storedProjectSettings = [project.path: ProjectSettings(accounts: [agent: .pool("team")])]
        preferences.sleepIdleThresholdSeconds = 0
        let fixed = Date()
        let ledger = CapacityLedger(now: { fixed })
        ledger.configure(pools: preferences.effectivePools,
                         accounts: preferences.preferences.accounts.map(CapacityPreferences.accountRef))
        let daemons = Daemons(), notices = Notices(), provider = Provider()
        retained.append(provider)
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences, daemonControl: daemons)
        store.launchFailureReporter = Reporter()
        store.statusRootOverride = dir("status")
        store.hookEventDirectoryOverride = dir("hooks")
        store.accountResolver = AccountResolver(preferences: preferences, ledger: ledger)
        store.notifier = notices
        store.handoffsNeedConfirmation = { false }
        let tab = store.newSession(in: project, agent: agent)
        let other = store.newSession(in: project, agent: agent)
        store.selectedSessionID = other.id
        store.apply(.activity(.idle), to: tab.id)
        return Rig(store: store, ledger: ledger, first: first, second: second, daemons: daemons,
                   notices: notices, provider: provider, tab: tab)
    }

    private func reading(_ account: AgentAccount, _ utilization: Double) -> UsageReading {
        UsageReading(account: CapacityPreferences.accountRef(account),
                     windows: [UsageWindow(name: "5h", utilization: utilization, resetsAt: nil)],
                     readAt: Date(), source: "test", hardRejection: false)
    }

    private func leases(_ rig: Rig) -> [UUID?] {
        rig.ledger.activeLeases(pool: "team").map(\.account.id)
    }

    private func freeze(_ rig: Rig) {
        rig.store.sleepController.tick()
        XCTAssertTrue(rig.store.sleepController.asleep.contains(rig.tab.id), "precondition: the tab froze")
    }

    private func settle(_ rig: Rig) async {
        for _ in 0..<200 where rig.store.rollingOver.contains(rig.tab.id) { await Task.yield() }
        XCTAssertFalse(rig.store.rollingOver.contains(rig.tab.id), "the rollover finished")
    }

    private func session(_ rig: Rig) -> Session? {
        rig.store.repos.flatMap(\.sessions).first { $0.id == rig.tab.id }
    }

    // MARK: 1. Freeze releases

    func testFreezingAnAgentReleasesItsLeaseAtOnce() {
        let rig = rig()
        rig.store.agentProcessRunning = { _ in true }
        XCTAssertEqual(rig.tab.accountID, rig.first.id)
        XCTAssertEqual(rig.store.accountResolver?.leases(heldBy: rig.tab.id).map(\.account.id), [rig.first.id],
                       "precondition: the tab leases first")
        let before = leases(rig).count

        freeze(rig)

        XCTAssertEqual(leases(rig).count, before - 1, "no 30 s grace: a frozen agent bills nothing")
        XCTAssertEqual(rig.store.accountResolver?.leases(heldBy: rig.tab.id), [])
        rig.store.reconcileTabLeases()
        XCTAssertEqual(rig.store.accountResolver?.leases(heldBy: rig.tab.id), [],
                       "the SIGSTOP'd process still reads running; the sweep must not re-lease it")
    }

    // MARK: 2. Thaw re-leases the same account

    /// `first` is past soft, so a fresh pick would choose `second`; the thaw re-leases `first`
    /// anyway, because the conversation lives in its home.
    func testThawReLeasesTheSameAccountEvenPastSoft() {
        let rig = rig()
        freeze(rig)
        rig.ledger.ingest(reading(rig.first, 0.9))
        rig.ledger.ingest(reading(rig.second, 0.1))

        rig.store.wakeIfAsleep(rig.tab.id)

        XCTAssertEqual(rig.daemons.conted, [rig.tab.id], "woken in place")
        XCTAssertEqual(rig.store.accountResolver?.leases(heldBy: rig.tab.id).map(\.account.id), [rig.first.id])
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)
        XCTAssertTrue(rig.notices.posted.isEmpty, "not spent: nothing to say")
    }

    // MARK: 3. Spent → rollover

    func testASpentAccountRollsAnIdleConversationToAnotherMemberWithItsDraft() async throws {
        let rig = rig()
        let id = rig.tab.pinnedConversationID
        let transcript = ClaudeSession.transcriptURL(
            sessionID: id, workingDirectory: rig.tab.transcriptDirectory,
            projectsRoot: rig.first.home.appendingPathComponent("projects"))
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"turn\":1}\n".write(to: transcript, atomically: true, encoding: .utf8)
        rig.store.injectorOverride = Composer("❯\u{a0}half a thought")
        freeze(rig)
        rig.ledger.ingest(reading(rig.first, 0.99))   // over hard
        rig.ledger.ingest(reading(rig.second, 0.1))
        let configsBefore = rig.provider.configs.count

        rig.store.wakeIfAsleep(rig.tab.id)
        await settle(rig)

        XCTAssertEqual(session(rig)?.accountID, rig.second.id, "same tab, now on second")
        XCTAssertEqual(session(rig)?.pinnedConversationID, id, "same conversation")
        let moved = ClaudeSession.transcriptURL(
            sessionID: id, workingDirectory: rig.tab.transcriptDirectory,
            projectsRoot: rig.second.home.appendingPathComponent("projects"))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "{\"turn\":1}\n",
                       "the transcript is where claude --resume looks under second's home")
        XCTAssertEqual(rig.daemons.terminated, [rig.tab.id], "the frozen agent on first is retired")
        XCTAssertEqual(rig.daemons.conted, [], "never woken on the spent account")
        XCTAssertFalse(rig.store.sleepController.asleep.contains(rig.tab.id))
        let relaunch = try XCTUnwrap(rig.provider.configs.dropFirst(configsBefore).last)
        XCTAssertTrue(relaunch.initialInput?.contains("claude --resume \(id.uuidString.lowercased())") ?? false,
                      "resumed, not launched fresh: \(relaunch.initialInput ?? "nil")")
        XCTAssertEqual(relaunch.environmentVariables["CLAUDE_CONFIG_DIR"], rig.second.home.path)
        XCTAssertEqual(rig.store.accountResolver?.leases(heldBy: rig.tab.id).map(\.account.id), [rig.second.id])
        XCTAssertEqual(rig.store.pendingDrafts[rig.tab.id]?.text, "half a thought")
        XCTAssertTrue(rig.notices.posted.contains { $0.body.contains("moved to “Second”") })

        // The resumed agent's composer comes up empty: the draft goes back in, unsent.
        let screen = Composer("❯\u{a0}Try \"fix lint errors\"")
        rig.store.injectorOverride = screen
        rig.store.applyRegistry([:])
        XCTAssertEqual(screen.pasted, ["half a thought"])
        XCTAssertNil(rig.store.pendingDrafts[rig.tab.id])
    }

    /// The user typed into the resumed composer first: theirs wins, nothing is spliced in.
    func testACarriedDraftNeverOverwritesTextTheUserAlreadyTyped() async throws {
        let rig = rig()
        rig.store.injectorOverride = Composer("❯ old draft")
        freeze(rig)
        rig.ledger.ingest(reading(rig.first, 0.99))
        rig.store.wakeIfAsleep(rig.tab.id)
        await settle(rig)
        XCTAssertEqual(rig.store.pendingDrafts[rig.tab.id]?.text, "old draft")

        let screen = Composer("❯ something new")
        rig.store.injectorOverride = screen
        rig.store.applyRegistry([:])
        XCTAssertEqual(screen.pasted, [])
        XCTAssertNil(rig.store.pendingDrafts[rig.tab.id])
    }

    // MARK: 4. No headroom → in place + notice

    func testWithNoOtherMemberUnderHardItThawsInPlaceAndSaysSo() {
        let rig = rig()
        rig.store.injectorOverride = Composer("❯")
        freeze(rig)
        rig.ledger.ingest(reading(rig.first, 0.99))
        rig.ledger.ingest(reading(rig.second, 0.98))

        rig.store.wakeIfAsleep(rig.tab.id)

        XCTAssertFalse(rig.store.rollingOver.contains(rig.tab.id))
        XCTAssertEqual(rig.daemons.conted, [rig.tab.id], "never a dead tab")
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)
        XCTAssertEqual(rig.store.accountResolver?.leases(heldBy: rig.tab.id).map(\.account.id), [rig.first.id],
                       "re-leased on the spent account")
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").filter { $0.account.id == rig.second.id }.count,
                       rig.store.repos.flatMap(\.sessions).filter { $0.accountID == rig.second.id }.count,
                       "the probe lease on second was given back")
        XCTAssertEqual(rig.notices.posted.map(\.title), ["Every account in “Team” is over its limit"])
    }

    // MARK: Tabs that cannot move stay, and say why

    /// Smart sleep also freezes an agent sitting in a dialog: a tool call is in flight, and
    /// killing the process would abandon it.
    func testAnAgentFrozenInADialogThawsInPlace() {
        let rig = rig()
        rig.store.apply(.activity(.waiting), to: rig.tab.id)
        rig.store.injectorOverride = Composer("❯")
        freeze(rig)
        rig.ledger.ingest(reading(rig.first, 0.99))
        rig.store.wakeIfAsleep(rig.tab.id)
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)
        XCTAssertEqual(rig.daemons.conted, [rig.tab.id])
        XCTAssertTrue(rig.notices.posted.contains { $0.body.contains("middle of a turn") }, "\(rig.notices.posted)")
    }

    /// No composer could be read at the freeze: a draft might be there, and a restart would
    /// lose it, so the conversation stays.
    func testAnUnreadableComposerThawsInPlace() {
        let rig = rig()
        freeze(rig)   // no injector: nothing to read
        rig.ledger.ingest(reading(rig.first, 0.99))
        rig.store.wakeIfAsleep(rig.tab.id)
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)
        XCTAssertTrue(rig.notices.posted.contains { $0.body.contains("unsent text") }, "\(rig.notices.posted)")
    }

    func testConfirmHandoffsKeepsTheTabInPlace() {
        let rig = rig()
        rig.store.handoffsNeedConfirmation = { true }
        rig.store.injectorOverride = Composer("❯")
        freeze(rig)
        rig.ledger.ingest(reading(rig.first, 0.99))
        rig.store.wakeIfAsleep(rig.tab.id)
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)
        XCTAssertTrue(rig.notices.posted.contains { $0.body.contains("need confirmation") }, "\(rig.notices.posted)")
    }

    // MARK: The resolver's half

    func testThawPlanOutsideAPoolIsAPlainWake() {
        let rig = rig()
        let outside = AgentAccount(agent: .claude, displayName: "Outside", home: dir("outside"))
        let plan = rig.store.accountResolver?.thawPlan(agent: .claude, project: dir("project").path,
                                                       account: outside, blocked: nil)
        XCTAssertEqual(plan, .inPlace(nil))
    }

    /// A provider refusal (a usage-limit rejection) is spent even with no utilization reading.
    func testARefusedAccountIsSpent() throws {
        let rig = rig()
        rig.ledger.ingest(UsageReading(account: CapacityPreferences.accountRef(rig.first), windows: [],
                                       readAt: Date(), source: "test", hardRejection: true))
        rig.ledger.ingest(reading(rig.second, 0.1))
        let plan = try XCTUnwrap(rig.store.accountResolver?.thawPlan(
            agent: .claude, project: dir("project").path, account: rig.first, blocked: nil))
        guard case .rollOver(let to, let resolution) = plan else { return XCTFail("expected a rollover, got \(plan)") }
        XCTAssertEqual(to.id, rig.second.id)
        rig.store.accountResolver?.release(resolution)
    }
}
