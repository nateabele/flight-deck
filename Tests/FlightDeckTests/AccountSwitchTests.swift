import FleetKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// `/switch-account`: a manual, live-tab trigger for the move smart sleep already makes at a
/// thaw (`SleepLeaseRolloverTests`). Covers naming (which account or pool a typed target means),
/// the refusals, the move itself through the store, and the control-socket and CLI plumbing.
@MainActor
final class AccountSwitchTests: XCTestCase {
    // MARK: Fixture

    private final class Daemons: DaemonControlling {
        var terminated: [UUID] = []
        func isLive(_ id: UUID) -> Bool { false }
        func isLive(socketPath: String) -> Bool { false }
        func daemonPID(_ id: UUID) -> pid_t? { 99_999_999 }
        func daemonPID(socketPath: String) -> pid_t? { nil }
        func terminate(_ id: UUID) { terminated.append(id) }
        func terminate(socketPath: String) {}
        func peerPID(socketPath: String) -> pid_t? { nil }
        func terminate(pid: pid_t, socketPath: String) {}
        func stop(_ id: UUID) {}
        func cont(_ id: UUID) {}
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

    /// A claude screen: rule, composer row, rule.
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
        suite = FileManager.default.temporaryDirectory.appendingPathComponent("account-switch-\(UUID().uuidString)", isDirectory: true)
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
        let preferences: PreferencesStore
        let ledger: CapacityLedger
        let resolver: AccountResolver
        let first: AgentAccount
        let second: AgentAccount
        let third: AgentAccount
        let solo: AgentAccount
        let daemons: Daemons
        let notices: Notices
        let provider: Provider
        let tab: Session
        let project: URL
    }

    /// Pool "Team" (First, Second, Third) assigned to the project, an unpooled "Solo", a removed
    /// "Gone" and another agent's "Codexy". The tab runs on First and is idle.
    private func rig(agent: AgentID = .claude) -> Rig {
        let first = AgentAccount(agent: agent, displayName: "First", home: dir("first"),
                                 cachedIdentity: AccountIdentity(email: "first@example.com"))
        let second = AgentAccount(agent: agent, displayName: "Second", home: dir("second"),
                                  cachedIdentity: AccountIdentity(email: "Second@Example.com"))
        let third = AgentAccount(agent: agent, displayName: "Third", home: dir("third"))
        let solo = AgentAccount(agent: agent, displayName: "Solo", home: dir("solo"),
                                cachedIdentity: AccountIdentity(email: "solo@example.com"))
        let gone = AgentAccount(agent: agent, displayName: "Gone", home: dir("gone"),
                                cachedIdentity: AccountIdentity(email: "gone@example.com"), removedAt: Date())
        let other = AgentAccount(agent: .codex, displayName: "Codexy", home: dir("codexy"),
                                 cachedIdentity: AccountIdentity(email: "codex@example.com"))
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.accountList = AccountList(entries: [
            .pool(AccountPool(id: "team", label: "Team", agent: agent, members: [first, second, third])),
            .account(solo), .account(gone), .account(other),
        ])
        let project = dir("project")
        preferences.preferences.storedProjectSettings = [project.path: ProjectSettings(accounts: [agent: .pool("team")])]
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
        let resolver = AccountResolver(preferences: preferences, ledger: ledger)
        store.accountResolver = resolver
        store.notifier = notices
        store.accountSwitchDelay = .zero
        let tab = store.newSession(in: project, agent: agent)
        store.apply(.activity(.idle), to: tab.id)
        return Rig(store: store, preferences: preferences, ledger: ledger, resolver: resolver, first: first,
                   second: second, third: third, solo: solo, daemons: daemons, notices: notices,
                   provider: provider, tab: tab, project: project)
    }

    private func reading(_ account: AgentAccount, _ utilization: Double) -> UsageReading {
        UsageReading(account: CapacityPreferences.accountRef(account),
                     windows: [UsageWindow(name: "5h", utilization: utilization, resetsAt: nil)],
                     readAt: Date(), source: "test", hardRejection: false)
    }

    private func decide(_ rig: Rig, _ target: String, current: AgentAccount? = nil) -> AccountSwitchDecision {
        rig.resolver.switchDecision(agent: .claude, current: current ?? rig.first, target: target)
    }

    private func settle(_ rig: Rig) async {
        for _ in 0..<2000 where rig.store.rollingOver.contains(rig.tab.id) { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(rig.store.rollingOver.contains(rig.tab.id), "the move finished")
    }

    private func session(_ rig: Rig) -> Session? {
        rig.store.repos.flatMap(\.sessions).first { $0.id == rig.tab.id }
    }

    // MARK: Target resolution

    func testATargetMatchesAnEmailCaseInsensitively() {
        let rig = rig()
        XCTAssertEqual(decide(rig, "SECOND@example.COM"), .move(to: rig.second, note: nil))
    }

    func testATargetMatchesADisplayNameCaseInsensitively() {
        let rig = rig()
        XCTAssertEqual(decide(rig, "  solo "), .move(to: rig.solo, note: nil))
    }

    func testATargetMatchesAnAccountId() {
        let rig = rig()
        XCTAssertEqual(decide(rig, rig.third.id.uuidString.lowercased()), .move(to: rig.third, note: nil))
    }

    func testATargetMatchesAPoolByLabelAndById() {
        let rig = rig()
        XCTAssertEqual(decide(rig, "team"), .move(to: rig.second, note: nil))
        XCTAssertEqual(decide(rig, "TEAM"), .move(to: rig.second, note: nil))
    }

    func testTheCurrentAccountIsANoOpNotAMove() {
        let rig = rig()
        XCTAssertEqual(decide(rig, "first"), .stay(rig.first))
        XCTAssertEqual(decide(rig, "first@example.com"), .stay(rig.first))
    }

    func testAnAmbiguousTargetListsItsCandidates() {
        let rig = rig()
        let twin = AgentAccount(agent: .claude, displayName: "second", home: dir("twin"))
        rig.preferences.preferences.accountList.entries.append(.account(twin))
        guard case .refuse(let message) = decide(rig, "Second") else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("more than one"), message)
        XCTAssertTrue(message.contains("Second@Example.com"), "names a candidate by email: \(message)")
        XCTAssertTrue(message.contains("“second”"), message)
    }

    func testAPoolAndAnAccountSharingANameAreAmbiguous() {
        let rig = rig()
        let namesake = AgentAccount(agent: .claude, displayName: "Team", home: dir("namesake"))
        rig.preferences.preferences.accountList.entries.append(.account(namesake))
        guard case .refuse(let message) = decide(rig, "team") else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("pool “Team”") && message.contains("“Team”"), message)
    }

    func testAnUnknownTargetListsTheValidChoices() {
        let rig = rig()
        guard case .refuse(let message) = decide(rig, "nobody") else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("“nobody”"), message)
        for choice in ["pool “Team”", "“First” (first@example.com)", "“Solo”"] {
            XCTAssertTrue(message.contains(choice), "\(choice) in: \(message)")
        }
    }

    func testARemovedAccountIsNeitherMatchedNorOffered() {
        let rig = rig()
        guard case .refuse(let message) = decide(rig, "gone@example.com") else { return XCTFail("expected a refusal") }
        XCTAssertFalse(message.contains("Gone"), message)
        guard case .refuse = decide(rig, "Gone") else { return XCTFail("a removed account is not a target") }
    }

    func testAnotherAgentsAccountsAreNeverTargets() {
        let rig = rig()
        guard case .refuse(let message) = decide(rig, "codex@example.com") else { return XCTFail("expected a refusal") }
        XCTAssertFalse(message.contains("Codexy"), "never offered: \(message)")
        guard case .refuse = decide(rig, "Codexy") else { return XCTFail("another agent's account is not a target") }
    }

    func testAnEmptyTargetListsTheChoices() {
        let rig = rig()
        guard case .refuse(let message) = decide(rig, "  ") else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("Choices:"), message)
    }

    // MARK: Pool pick

    func testAPoolPicksTheFirstMemberBelowItsLimitSkippingTheCurrentOne() {
        let rig = rig()
        rig.ledger.ingest(reading(rig.first, 0.10))    // the current account: under soft, but skipped
        rig.ledger.ingest(reading(rig.second, 0.85))   // over soft: not below its limit
        rig.ledger.ingest(reading(rig.third, 0.10))
        XCTAssertEqual(decide(rig, "Team"), .move(to: rig.third, note: nil))
    }

    func testAMemberWithNoReadingCountsAsBelowItsLimit() {
        let rig = rig()
        rig.ledger.ingest(reading(rig.third, 0.10))
        XCTAssertEqual(decide(rig, "Team"), .move(to: rig.second, note: nil), "pool order, an idle account is usable")
    }

    func testAPoolWithNoMemberBelowItsLimitRefusesNamingThePool() {
        let rig = rig()
        rig.ledger.ingest(reading(rig.second, 0.85))
        rig.ledger.ingest(reading(rig.third, 0.99))
        guard case .refuse(let message) = decide(rig, "Team") else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("pool “Team”"), message)
    }

    func testAnExplicitAccountOverItsHardLimitMovesAnywayAndSaysSo() {
        let rig = rig()
        rig.ledger.ingest(reading(rig.second, 0.99))
        guard case .move(let account, let note) = decide(rig, "Second") else { return XCTFail("expected a move") }
        XCTAssertEqual(account, rig.second)
        XCTAssertTrue(note?.contains("over its hard limit") ?? false, "\(note ?? "nil")")
    }

    // MARK: The picker's list

    func testChoicesListPoolsWithMembersThenUnpooledAccountsAndMarkTheCurrentOne() {
        let rig = rig()
        rig.ledger.ingest(reading(rig.second, 0.85))
        rig.ledger.ingest(reading(rig.third, 0.99))
        let choices = rig.resolver.choices(agent: .claude, project: rig.project.path, current: rig.first)
        XCTAssertEqual(choices.current, rig.first.id.uuidString)
        XCTAssertEqual(choices.assignedPool, "team")
        XCTAssertEqual(choices.pools.map(\.id), ["team"])
        XCTAssertEqual(choices.pools[0].isAssigned, true)
        XCTAssertEqual(choices.pools[0].members.map(\.displayName), ["First", "Second", "Third"])
        XCTAssertEqual(choices.pools[0].members.map(\.isCurrent), [true, false, false])
        XCTAssertEqual(choices.pools[0].members.map(\.state), ["unknown", "overSoft", "overHard"])
        XCTAssertEqual(choices.pools[0].members[1].email, "Second@Example.com")
        XCTAssertNil(choices.pools[0].members[2].email)
        XCTAssertEqual(choices.accounts.map(\.displayName), ["Solo"], "no removed account, no other agent's")
    }

    // MARK: Refusals

    func testAnUnknownTabIsRefused() {
        let rig = rig()
        let result = rig.store.requestAccountSwitch(UUID(), target: "Second")
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(result.message.contains("No such tab"))
        XCTAssertNil(rig.store.accountChoices(for: UUID()))
    }

    func testAnAgentThatCannotTransferAConversationIsRefused() {
        let rig = rig(agent: .gemini)
        let result = rig.store.requestAccountSwitch(rig.tab.id, target: "Second")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("cannot carry a conversation"), result.message)
        XCTAssertTrue(rig.store.rollingOver.isEmpty)
    }

    func testAMidTurnTabIsRefusedAndNothingIsKilled() {
        let rig = rig()
        rig.store.apply(.activity(.busy), to: rig.tab.id)
        let result = rig.store.requestAccountSwitch(rig.tab.id, target: "Second")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("mid-turn"), result.message)
        XCTAssertTrue(rig.daemons.terminated.isEmpty)
        XCTAssertTrue(rig.store.rollingOver.isEmpty)
    }

    func testASwarmAgentIsRefused() {
        let rig = rig()
        let swarm = SwarmRig()
        var agent = swarm.agent("BlueLake", state: .working, task: "fx-1")
        agent.session = rig.tab.id
        swarm.store.save([swarm.record(state: .paused, agents: [agent])])
        rig.store.useSwarmService(SwarmService(store: swarm.store, backend: swarm.backend, launcher: swarm.launcher,
                                               spawner: nil, host: swarm.host, registry: RoutingCapabilityRegistry([]),
                                               clock: nil))
        let result = rig.store.requestAccountSwitch(rig.tab.id, target: "Second")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("swarm agent"), result.message)
    }

    func testASleepingTabIsRefused() {
        let rig = rig()
        rig.preferences.sleepIdleThresholdSeconds = 0
        let other = rig.store.newSession(in: rig.project, agent: .claude)
        rig.store.selectedSessionID = other.id
        rig.store.sleepController.tick()
        XCTAssertTrue(rig.store.sleepController.asleep.contains(rig.tab.id), "precondition: the tab froze")
        let result = rig.store.requestAccountSwitch(rig.tab.id, target: "Second")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("asleep"), result.message)
    }

    func testTheCurrentAccountAnswersAlreadyOnAndMovesNothing() {
        let rig = rig()
        let result = rig.store.requestAccountSwitch(rig.tab.id, target: "first@example.com")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "Already on “First”.")
        XCTAssertNil(result.to)
        XCTAssertTrue(rig.store.rollingOver.isEmpty)
    }

    func testASecondRequestWhileOneIsMovingIsRefused() async {
        let rig = rig()
        rig.store.injectorOverride = Composer("❯")
        XCTAssertTrue(rig.store.requestAccountSwitch(rig.tab.id, target: "Second").ok)
        let again = rig.store.requestAccountSwitch(rig.tab.id, target: "Third")
        XCTAssertFalse(again.ok)
        XCTAssertTrue(again.message.contains("already moving"), again.message)
        await settle(rig)
        XCTAssertEqual(session(rig)?.accountID, rig.second.id, "only the first request moved it")
    }

    // MARK: The move

    func testALiveIdleTabMovesToAPoolMemberWithItsDraftAndLease() async throws {
        let rig = rig()
        let id = rig.tab.pinnedConversationID
        let transcript = ClaudeSession.transcriptURL(
            sessionID: id, workingDirectory: rig.tab.transcriptDirectory,
            projectsRoot: rig.first.home.appendingPathComponent("projects"))
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"turn\":1}\n".write(to: transcript, atomically: true, encoding: .utf8)
        rig.store.injectorOverride = Composer("❯\u{a0}half a thought")
        rig.ledger.ingest(reading(rig.second, 0.90))   // over soft: the pool skips it
        let configsBefore = rig.provider.configs.count

        let result = rig.store.requestAccountSwitch(rig.tab.id, target: "Team")

        // Answered first: nothing has been killed or moved when the reply is in hand.
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.to, "Third")
        XCTAssertTrue(rig.daemons.terminated.isEmpty, "the asking process is still alive to read its answer")
        XCTAssertTrue(rig.store.rollingOver.contains(rig.tab.id))
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)

        await settle(rig)

        XCTAssertEqual(session(rig)?.accountID, rig.third.id, "same tab, now on third")
        XCTAssertEqual(session(rig)?.pinnedConversationID, id, "same conversation")
        let moved = ClaudeSession.transcriptURL(
            sessionID: id, workingDirectory: rig.tab.transcriptDirectory,
            projectsRoot: rig.third.home.appendingPathComponent("projects"))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "{\"turn\":1}\n")
        XCTAssertEqual(rig.daemons.terminated, [rig.tab.id], "the live agent on first is retired")
        let relaunch = try XCTUnwrap(rig.provider.configs.dropFirst(configsBefore).last)
        XCTAssertTrue(relaunch.initialInput?.contains("claude --resume \(id.uuidString.lowercased())") ?? false,
                      "resumed, not launched fresh: \(relaunch.initialInput ?? "nil")")
        XCTAssertEqual(relaunch.environmentVariables["CLAUDE_CONFIG_DIR"], rig.third.home.path)
        XCTAssertEqual(rig.store.accountResolver?.leases(heldBy: rig.tab.id).map(\.account.id), [rig.third.id],
                       "the old lease is released and the pool member's taken")
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").map(\.account.id), [rig.third.id])
        XCTAssertEqual(rig.store.pendingDrafts[rig.tab.id]?.text, "half a thought")
        let notice = try XCTUnwrap(rig.notices.posted.last)
        XCTAssertTrue(notice.title.contains("Moved to “Third”"), notice.title)
        XCTAssertTrue(notice.body.contains("You asked"), "says the user asked, not that a limit was hit: \(notice.body)")
        XCTAssertFalse(notice.title.contains("over its limit"))
    }

    /// The "Concept Codes" report (2026-10-13): the old agent outlived the move — its daemon had
    /// no pidfile — and its registry row kept the tab anchored to it. The resumed agent's
    /// question read as the old one's idle `shell`, and no phone was ever offered it.
    func testAMovedTabFollowsTheResumedAgentEvenWhileTheOldOneLingers() async {
        let rig = rig()
        let id = rig.tab.pinnedConversationID
        let old = ClaudeStatusFile.Entry(pid: 34307, sessionID: id, activity: .idle, waitingFor: nil,
                                         startedAt: 1, procStart: "old")
        rig.store.applyRegistry([old.pid: old])
        rig.store.injectorOverride = Composer("❯")
        XCTAssertTrue(rig.store.requestAccountSwitch(rig.tab.id, target: "Second").ok)
        await settle(rig)
        XCTAssertEqual(session(rig)?.accountID, rig.second.id)

        let lingering = ClaudeStatusFile.Entry(pid: 34307, sessionID: id, activity: .idle, waitingFor: nil,
                                               startedAt: 1, procStart: "old", reportsBackgroundWork: true)
        let resumed = ClaudeStatusFile.Entry(pid: 17193, sessionID: id, activity: .waiting,
                                             waitingFor: "input needed", startedAt: 2, procStart: "new")
        rig.store.applyRegistry([lingering.pid: lingering, resumed.pid: resumed])
        XCTAssertEqual(rig.store.statuses[rig.tab.id]?.activity, .waiting,
                       "the tab reads the resumed agent, not the one the move retired")
    }

    func testAMoveToAnAccountOutsideTheAssignedPoolHoldsNoLease() async {
        let rig = rig()
        XCTAssertFalse(rig.store.accountResolver?.leases(heldBy: rig.tab.id).isEmpty ?? true, "precondition: leased on first")
        rig.store.injectorOverride = Composer("❯")
        XCTAssertTrue(rig.store.requestAccountSwitch(rig.tab.id, target: "Solo").ok)
        await settle(rig)
        XCTAssertEqual(session(rig)?.accountID, rig.solo.id)
        XCTAssertEqual(rig.store.accountResolver?.leases(heldBy: rig.tab.id), [], "solo is in no pool the project bills")
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team"), [])
    }

    func testAnExplicitOverHardAccountIsMovedToAndTheResultSaysSo() async {
        let rig = rig()
        rig.store.injectorOverride = Composer("❯")
        rig.ledger.ingest(reading(rig.second, 0.99))
        let result = rig.store.requestAccountSwitch(rig.tab.id, target: "Second")
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.message.contains("over its hard limit"), result.message)
        await settle(rig)
        XCTAssertEqual(session(rig)?.accountID, rig.second.id)
    }

    func testATurnStartedAfterTheAnswerCancelsTheMoveAndSaysSo() async {
        let rig = rig()
        rig.store.injectorOverride = Composer("❯")
        XCTAssertTrue(rig.store.requestAccountSwitch(rig.tab.id, target: "Second").ok)
        rig.store.apply(.activity(.busy), to: rig.tab.id)   // before the scheduled move looks again
        await settle(rig)
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)
        XCTAssertTrue(rig.daemons.terminated.isEmpty)
        XCTAssertTrue(rig.notices.posted.last?.title.contains("Did not move") ?? false)
    }

    func testAnUnreadableComposerCancelsTheMoveRatherThanRiskTheDraft() async {
        let rig = rig()   // no injector, no surface: the composer cannot be read
        XCTAssertTrue(rig.store.requestAccountSwitch(rig.tab.id, target: "Second").ok)
        await settle(rig)
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)
        XCTAssertTrue(rig.daemons.terminated.isEmpty)
        XCTAssertTrue(rig.notices.posted.last?.body.contains("could not read") ?? false)
    }

    func testAFailedCopyLeavesTheLiveAgentWhereItIs() async throws {
        let rig = rig()
        let id = rig.tab.pinnedConversationID
        let transcript = ClaudeSession.transcriptURL(
            sessionID: id, workingDirectory: rig.tab.transcriptDirectory,
            projectsRoot: rig.first.home.appendingPathComponent("projects"))
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"turn\":1}\n".write(to: transcript, atomically: true, encoding: .utf8)
        // A FILE where the destination's projects directory belongs: the copy cannot be made.
        try "x".write(to: rig.second.home.appendingPathComponent("projects"), atomically: true, encoding: .utf8)
        rig.store.injectorOverride = Composer("❯")
        XCTAssertTrue(rig.store.requestAccountSwitch(rig.tab.id, target: "Second").ok)
        await settle(rig)
        XCTAssertEqual(session(rig)?.accountID, rig.first.id)
        XCTAssertTrue(rig.daemons.terminated.isEmpty, "nothing is killed when the conversation could not be carried")
        XCTAssertTrue(rig.notices.posted.last?.title.contains("Could not move") ?? false)
    }

    // MARK: Control scope

    func testControlScopeAllowsOnlyOwnTabSwitchesUnderOwnSession() {
        let me = UUID(), other = UUID()
        let mine = FleetRequest.accountSwitch(session: me, target: "x")
        let theirs = FleetRequest.accountSwitch(session: other, target: "x")
        for level in [ControlScopeLevel.full] {
            XCTAssertTrue(ControlScope.permits(theirs, level: level, caller: .session(me)))
        }
        XCTAssertTrue(ControlScope.permits(mine, level: .ownSession, caller: .session(me)))
        XCTAssertFalse(ControlScope.permits(theirs, level: .ownSession, caller: .session(me)))
        XCTAssertTrue(ControlScope.permits(theirs, level: .ownSession, caller: .human), "a human shell is never scoped")
        XCTAssertFalse(ControlScope.permits(mine, level: .readOnly, caller: .session(me)), "a switch is a write")
        XCTAssertFalse(ControlScope.permits(mine, level: .ownSession, caller: .invalid))
        XCTAssertTrue(ControlScope.permits(.accountList(session: other), level: .readOnly, caller: .session(me)),
                      "listing reads only")
    }

    // MARK: Wire

    func testTheAccountRequestsAndRepliesRoundTripTheWire() throws {
        let id = UUID()
        for request in [FleetRequest.accountList(session: id), .accountSwitch(session: id, target: "a b@c.d")] {
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), request)
        }
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(FleetRequest.accountSwitch(session: id, target: "t")), encoding: .utf8))
        XCTAssertTrue(json.contains("\"op\":\"account.switch\""), json)
        let choices = WireAccountChoices(agent: "claude", current: "a", assignedPool: nil, pools: [
            WireAccountPoolChoice(id: "p", label: "P", isAssigned: false, members: [
                WireAccountChoice(id: "a", displayName: "A", email: nil, state: "unknown", isCurrent: true),
            ]),
        ], accounts: [])
        for (frame, cid) in [(ServerFrame.accountChoices(cid: 3, choices), 3),
                             (.accountSwitched(cid: 4, WireAccountSwitchResult(ok: true, message: "m", to: "B")), 4)] {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
            XCTAssertEqual(frame.correlationID, cid)
            XCTAssertFalse(frame.continuesStream)
        }
    }

    // MARK: Over the real local control socket

    func testListAndSwitchRoundTripOverTheLocalControlSocket() async throws {
        let rig = rig()
        rig.store.injectorOverride = Composer("❯")
        let harness = FleetTestHarness(store: rig.store)
        let path = "/tmp/fdacct-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
        defer { harness.service.stop(); unlink(path) }

        func ask(_ request: FleetRequest, caller: String? = nil) async throws -> ServerFrame {
            let client = FleetClient(localCaller: caller)
            defer { client.disconnect() }
            var cid: Int?
            var reply: ServerFrame?
            let ready = XCTestExpectation(description: "snapshot"); ready.assertForOverFulfill = false
            let answered = XCTestExpectation(description: "reply")
            client.onFrame = { frame in
                if case .snapshot = frame { ready.fulfill() }
                if let cid, frame.correlationID == cid { reply = frame; answered.fulfill() }
            }
            client.connect(toLocal: path, lastSeq: 0)
            await XCTWaiter().fulfillment(of: [ready], timeout: 5)
            cid = client.send(request)
            await XCTWaiter().fulfillment(of: [answered], timeout: 5)
            return try XCTUnwrap(reply)
        }

        guard case .accountChoices(_, let choices) = try await ask(.accountList(session: rig.tab.id)) else {
            return XCTFail("expected the choices")
        }
        XCTAssertEqual(choices.current, rig.first.id.uuidString)
        XCTAssertEqual(choices.pools.first?.members.count, 3)

        guard case .err(_, "unknown_session", _) = try await ask(.accountList(session: UUID())) else {
            return XCTFail("an unknown tab has no choices")
        }

        // Scoped to its own tab: another tab's switch is out of scope, its own goes through.
        harness.service.scopeLevel = { .ownSession }
        let stranger = ControlEnvironment.token(for: UUID(), secret: harness.service.controlSecret)
        guard case .err(_, "out_of_scope", _) = try await ask(.accountSwitch(session: rig.tab.id, target: "Second"), caller: stranger)
        else { return XCTFail("a tab may not move another tab") }
        XCTAssertTrue(rig.store.rollingOver.isEmpty)

        let own = ControlEnvironment.token(for: rig.tab.id, secret: harness.service.controlSecret)
        guard case .accountSwitched(_, let result) = try await ask(.accountSwitch(session: rig.tab.id, target: "Second"), caller: own)
        else { return XCTFail("expected the switch result") }
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.to, "Second")
        await settle(rig)
        XCTAssertEqual(session(rig)?.accountID, rig.second.id)
    }
}

/// `flightdeck account …`.
final class AccountSwitchCLITests: XCTestCase {
    private func parse(_ args: String...) throws -> CLIInvocation { try CLIArguments.parse(args) }

    func testListDefaultsToSelfAndTakesJSONAnywhere() throws {
        XCTAssertEqual(try parse("account", "list").command, .accountList(session: "self"))
        let json = try parse("account", "list", "--json")
        XCTAssertEqual(json.command, .accountList(session: "self"))
        XCTAssertTrue(json.json)
        XCTAssertEqual(try parse("account", "list", "--session", "alpha").command, .accountList(session: "alpha"))
        XCTAssertEqual(try parse("account", "ls").command, .accountList(session: "self"))
    }

    func testSwitchTakesTheWholeTargetAndASession() throws {
        XCTAssertEqual(try parse("account", "switch", "work@example.com").command,
                       .accountSwitch(session: "self", target: "work@example.com"))
        XCTAssertEqual(try parse("account", "switch", "My", "Work", "--session", "abcd1234").command,
                       .accountSwitch(session: "abcd1234", target: "My Work"))
    }

    func testADashLedTargetGoesAfterTheLiteralSeparator() throws {
        XCTAssertEqual(try parse("account", "switch", "--", "-odd").command,
                       .accountSwitch(session: "self", target: "-odd"))
    }

    func testMissingPiecesAreUsageErrors() {
        XCTAssertThrowsError(try parse("account"))
        XCTAssertThrowsError(try parse("account", "switch"))
        XCTAssertThrowsError(try parse("account", "frobnicate"))
        XCTAssertThrowsError(try parse("account", "list", "--bogus"))
    }

    func testListPrintsPoolsWithIndentedMembersThenUnpooledAccounts() {
        let choices = WireAccountChoices(agent: "claude", current: "a", assignedPool: "team", pools: [
            WireAccountPoolChoice(id: "team", label: "Team", isAssigned: true, members: [
                WireAccountChoice(id: "a", displayName: "First", email: "f@x.io", state: "underSoft", isCurrent: true),
                WireAccountChoice(id: "b", displayName: "Second", email: nil, state: "overHard", isCurrent: false),
            ]),
        ], accounts: [WireAccountChoice(id: "c", displayName: "Solo", email: nil, state: "unknown", isCurrent: false)])
        XCTAssertEqual(CLIOutput.accountChoices(choices), """
            Team  (pool team, assigned to this project)
              * First <f@x.io>  under soft
                Second  over hard
            No pool
                Solo  unknown
            """)
    }

    func testARefusalIsExitOneWithTheMessageOnStderrAndSuccessPrintsIt() throws {
        let tab = UUID()
        var out: [String] = [], err: [String] = []
        var code: Int32?
        func run(_ args: [String], reply: WireAccountSwitchResult) throws {
            out = []; err = []; code = nil
            let transport = FakeTransport()
            let runner = CLIRunner(invocation: try CLIArguments.parse(args), transport: transport,
                                   context: CLIContext(selfID: tab, cwd: "/", json: false, isTTY: false),
                                   out: { out.append($0) }, err: { err.append($0) }, finish: { code = $0 },
                                   schedule: { _, _ in })
            runner.run()
            transport.push(.snapshot(seq: 1, fleet: FleetSnapshot(projects: [
                WireProject(id: UUID(), name: "p", path: "/p", sessions: [WireSession(id: tab, title: "t", agent: "claude")]),
            ]), reason: .initial))
            guard case .req(let cid, .accountSwitch(tab, let target)) = transport.sent.last else { return XCTFail("\(transport.sent)") }
            XCTAssertEqual(target, args[2])
            transport.push(.accountSwitched(cid: cid, reply))
        }
        try run(["account", "switch", "nope"], reply: WireAccountSwitchResult(ok: false, message: "No match for nope."))
        XCTAssertEqual(code, 1)
        XCTAssertEqual(err, ["flightdeck: No match for nope."])
        XCTAssertTrue(out.isEmpty)

        try run(["account", "switch", "Second"], reply: WireAccountSwitchResult(ok: true, message: "Moving.", to: "Second"))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, ["Moving."])
    }
}
