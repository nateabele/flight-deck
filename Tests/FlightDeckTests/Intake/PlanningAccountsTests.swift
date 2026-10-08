import Darwin
import Foundation
import XCTest
import IntakeKit
@testable import FlightDeck

/// Unify brief R9: planning bills the project's account or pool for each seat's agent. Pins the
/// resolution rules, the runner's `accounts.json` hand-off, and the pool-lease lifecycle across
/// a runner's start, normal exit, crash, failed spawn and an app relaunch with a live runner.
@MainActor
final class PlanningAccountsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short and space-free for `sun_path`, as `IntakeRunnerControllerTests` explains.
        tempDir = URL(fileURLWithPath: "/tmp/pat-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private let project = "/w/proj"
    private lazy var work = AgentAccount(agent: .claude, displayName: "Work", home: tempDir.appendingPathComponent("work"))
    private lazy var spare = AgentAccount(agent: .claude, displayName: "Spare", home: tempDir.appendingPathComponent("spare"))
    private lazy var personal = AgentAccount(agent: .claude, displayName: "Personal", home: tempDir.appendingPathComponent("personal"))
    private lazy var codex = AgentAccount(agent: .codex, displayName: "CX", home: tempDir.appendingPathComponent("cx"))

    /// `personal` and `codex` at top level; `work` then `spare` in the "Team" pool.
    private func preferences(_ assignments: [AgentID: AccountAssignment] = [:]) -> PreferencesStore {
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [
            .account(personal), .account(codex),
            .pool(AccountPool(id: "team", label: "Team", agent: .claude, members: [work, spare])),
        ])
        store.preferences.storedProjectSettings = [project: ProjectSettings(accounts: assignments)]
        return store
    }

    private func ledger(for store: PreferencesStore) -> CapacityLedger {
        let ledger = CapacityLedger()
        ledger.configure(pools: store.effectivePools, accounts: store.preferences.accounts.map(CapacityPreferences.accountRef))
        return ledger
    }

    private func overSoft(_ account: AgentAccount, in ledger: CapacityLedger) {
        ledger.ingest(UsageReading(account: CapacityPreferences.accountRef(account),
                                   windows: [UsageWindow(name: "five_hour", utilization: 0.9, resetsAt: nil)],
                                   readAt: Date(), source: "test", hardRejection: false))
    }

    // MARK: - Round config and the hand-off file

    func testARoundConfigNamesEveryAgentAnySeatCanRunFallbacksIncluded() {
        let codexA = ModelChoice(agent: .codex, model: "A", effort: "high")
        let claudeB = ModelChoice(agent: .claude, model: "B", effort: "high")
        let grok = ModelChoice(agent: .grok, model: "g", effort: "high")
        let gemini = ModelChoice(agent: .gemini, model: "m", effort: "high")
        let config = RoundConfig(drafters: [Slot(codexA, fallback: grok)], synthesizer: nil, reviewer: Slot(codexA),
                                 integrator: codexA, encoder: codexA, polisher: nil, refinementCap: 1, polishCap: 1,
                                 freshEyesAndDedup: false, defaultPlay: .step, customized: false,
                                 crossReviewer: Slot(gemini), crossCheck: .every)
        XCTAssertEqual(config.agents, [.codex, .grok, .gemini])
        var withPolisher = config
        withPolisher.polisher = claudeB
        XCTAssertEqual(withPolisher.agents, [.codex, .grok, .gemini, .claude])
    }

    func testRunnerAccountsRoundTripThroughTheIntakeDirectory() throws {
        let dir = tempDir.appendingPathComponent("intake")
        XCTAssertNil(RunnerAccounts.load(from: dir), "no file reads as nil — every seat on its built-in home")
        let lease = AccountLease(pool: "team", account: CapacityPreferences.accountRef(work))
        let accounts = RunnerAccounts(agents: [
            .claude: RunnerAccounts.Entry(accountID: work.id, home: work.home, label: "Team pool · Work", lease: StoredLease(lease)),
            .grok: RunnerAccounts.Entry(accountID: nil, home: nil, label: "Grok built-in"),
        ])
        try accounts.write(to: dir)
        let read = try XCTUnwrap(RunnerAccounts.load(from: dir))
        XCTAssertEqual(read, accounts)
        XCTAssertEqual(read.leases, [lease])
        XCTAssertEqual(read.agents[.claude]?.ref, AgentAccountRef(id: work.id.uuidString, home: work.home))
        XCTAssertNil(read.agents[.grok]?.ref)
        let json = String(decoding: try Data(contentsOf: RunnerAccounts.url(in: dir)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""claude""#) && json.contains(#""grok""#), "keyed by agent raw value: \(json)")
    }

    // MARK: - Resolution

    func testNoAssignmentBillsTheAgentsFirstLiveAccountAsTabsDo() throws {
        let store = preferences()
        let resolver = AccountResolver(preferences: store, ledger: ledger(for: store))
        let claude = try resolver.acquire(.claude, project: project).get()
        XCTAssertEqual(claude.account?.id, personal.id)
        XCTAssertNil(claude.lease)
        XCTAssertEqual(claude.account?.id, store.account(for: .claude, project: project)?.id, "the same answer a new tab gets")
        XCTAssertEqual(try resolver.acquire(.codex, project: project).get().account?.id, codex.id)
        XCTAssertEqual(resolver.billing(.claude, project: project), AccountBilling(text: "Personal"))
    }

    func testAnAssignedAccountIsBilled() throws {
        let store = preferences([.claude: .account(spare.id)])
        let resolver = AccountResolver(preferences: store, ledger: ledger(for: store))
        let entry = try resolver.acquire(.claude, project: project).get().entry
        XCTAssertEqual(entry.accountID, spare.id)
        XCTAssertEqual(entry.home, spare.home)
        XCTAssertNil(entry.lease)
        XCTAssertEqual(resolver.billing(.claude, project: project).text, "Spare")
    }

    /// No account record at all (grok/gemini on an install that never seeded one): the CLI's
    /// built-in home, no id to credit.
    func testAnAgentWithNoAccountRecordRunsInItsBuiltInHome() throws {
        let store = preferences()
        let resolver = AccountResolver(preferences: store, ledger: ledger(for: store))
        let grok = try resolver.acquire(.grok, project: project).get()
        XCTAssertNil(grok.account)
        XCTAssertNil(grok.entry.home)
        XCTAssertNil(grok.entry.accountID)
        XCTAssertEqual(resolver.billing(.grok, project: project).text, "Grok built-in")
    }

    /// The built-in account is credited by id, but its CLI is not handed its default home
    /// explicitly (claude reads a different Keychain entry when `CLAUDE_CONFIG_DIR` is set).
    func testTheBuiltInAccountIsCreditedButLeavesTheHomeUnbound() throws {
        let builtIn = AgentAccount(agent: .codex, displayName: "Default", home: AgentID.codex.builtInHome)
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [.account(builtIn)])
        let entry = try AccountResolver(preferences: store, ledger: CapacityLedger()).acquire(.codex, project: project).get().entry
        XCTAssertEqual(entry.accountID, builtIn.id)
        XCTAssertNil(entry.home)
    }

    func testAPoolLeasesTheFirstAccountUnderSoft() throws {
        let store = preferences([.claude: .pool("team")])
        let ledger = ledger(for: store)
        overSoft(work, in: ledger)
        let resolver = AccountResolver(preferences: store, ledger: ledger)
        XCTAssertEqual(resolver.billing(.claude, project: project), AccountBilling(text: "Team pool"))
        let resolved = try resolver.acquire(.claude, project: project).get()
        XCTAssertEqual(resolved.account?.id, spare.id, "Work is over soft, so Spare is leased")
        XCTAssertEqual(resolved.label, "Team pool · Spare")
        XCTAssertEqual(ledger.activeLeases(pool: "team").count, 1)
        resolver.release(try XCTUnwrap(resolved.lease))
        XCTAssertEqual(ledger.activeLeases(pool: "team").count, 0)
    }

    /// A broken assignment refuses rather than silently billing another login.
    func testABrokenAssignmentRefusesAndTheEditorSaysSo() {
        let store = preferences([.claude: .account(UUID()), .codex: .pool("gone")])
        let resolver = AccountResolver(preferences: store, ledger: ledger(for: store))
        XCTAssertEqual(resolver.acquire(.claude, project: project).failure, .accountMissing(.claude))
        XCTAssertEqual(resolver.acquire(.codex, project: project).failure, .poolUnavailable("gone", .codex))
        XCTAssertTrue(resolver.billing(.claude, project: project).problem)
        XCTAssertTrue(resolver.billing(.codex, project: project).problem)
    }

    /// A pool with every member over SOFT still runs inside the pool — on its first over-soft
    /// member in lease order, unleased and with no notice (soft means "prefer another", not
    /// "stop") — and never on a login outside it. The tab rule, from the shared resolver.
    func testAPoolWithEveryMemberOverSoftRunsOnItsFirstOverSoftMemberUnleased() throws {
        let store = preferences([.claude: .pool("team")])
        let ledger = ledger(for: store)
        overSoft(work, in: ledger)
        ledger.ingest(UsageReading(account: CapacityPreferences.accountRef(spare),
                                   windows: [UsageWindow(name: "five_hour", utilization: 0.85, resetsAt: nil)],
                                   readAt: Date(), source: "test", hardRejection: false))
        let resolved = try AccountResolver(preferences: store, ledger: ledger).acquire(.claude, project: project).get()
        XCTAssertEqual(resolved.account?.id, work.id)
        XCTAssertNil(resolved.lease)
        XCTAssertNil(resolved.notice)
        XCTAssertEqual(ledger.activeLeases(pool: "team").count, 0)
    }

    private func overHard(_ account: AgentAccount, _ utilization: Double, in ledger: CapacityLedger) {
        ledger.ingest(UsageReading(account: CapacityPreferences.accountRef(account),
                                   windows: [UsageWindow(name: "five_hour", utilization: utilization, resetsAt: nil)],
                                   readAt: Date(), source: "test", hardRejection: false))
    }

    /// Every member over HARD: the seat runs on the member with the most headroom, unleased,
    /// and carries the tab's over-limit notice so planning can tell the user.
    func testAPoolWithEveryMemberOverHardCarriesTheOverLimitNotice() throws {
        let store = preferences([.claude: .pool("team")])
        let ledger = ledger(for: store)
        overHard(work, 1.0, in: ledger)
        overHard(spare, 0.99, in: ledger)
        let resolved = try AccountResolver(preferences: store, ledger: ledger).acquire(.claude, project: project).get()
        XCTAssertEqual(resolved.account?.id, spare.id, "most headroom")
        XCTAssertNil(resolved.lease)
        let notice = try XCTUnwrap(resolved.notice)
        XCTAssertEqual(notice.title, "Every account in “Team” is over its limit")
        XCTAssertTrue(notice.body.contains("Spare"), notice.body)
    }

    /// A runner started on an all-over-hard pool tells the user once, after the start succeeded.
    func testARunnerStartOnAnAllOverHardPoolPostsTheNotice() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let rig = try rig(clock: { now })
        overHard(work, 1.0, in: rig.ledger)
        overHard(spare, 1.0, in: rig.ledger)
        var heard: [(UUID, String, AccountNotice)] = []
        rig.controller.onAccountNotice = { heard.append(($0, $1, $2)) }
        rig.spawner.onSpawn = { self.goLive(rig) }
        XCTAssertNoThrow(try rig.controller.ensureRunning(rig.id).get())
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first?.0, rig.id)
        XCTAssertEqual(heard.first?.1, project)
        XCTAssertEqual(heard.first?.2.title, "Every account in “Team” is over its limit")
        _ = now
    }

    /// A start refused for another agent's broken assignment says nothing about the pool it
    /// briefly resolved: the run never started.
    func testARefusedStartPostsNoOverLimitNotice() throws {
        let rig = try rig([.claude: .pool("team"), .codex: .account(UUID())], clock: { Date() })
        overHard(work, 1.0, in: rig.ledger)
        overHard(spare, 1.0, in: rig.ledger)
        var heard = 0
        rig.controller.onAccountNotice = { _, _, _ in heard += 1 }
        guard case .failure(.accountUnavailable) = rig.controller.ensureRunning(rig.id) else {
            return XCTFail("expected an account refusal")
        }
        XCTAssertEqual(heard, 0)
    }

    func testAPoolWithNoLiveMemberIsUnavailable() {
        let store = preferences([.claude: .pool("empty")])
        try? store.updateAccountList { list throws(AccountListError) in
            try list.addPool(AccountPool(id: "empty", label: "Empty", agent: .claude))
        }
        let resolver = AccountResolver(preferences: store, ledger: ledger(for: store))
        XCTAssertEqual(resolver.acquire(.claude, project: project).failure, .poolUnavailable("empty", .claude))
    }

    /// All-or-nothing: a failure on one agent hands back the lease another already took.
    func testAcquiringSeveralAgentsReleasesEarlierLeasesWhenOneFails() {
        let store = preferences([.claude: .pool("team"), .codex: .account(UUID())])
        let ledger = ledger(for: store)
        let resolver = AccountResolver(preferences: store, ledger: ledger)
        XCTAssertEqual(resolver.acquire([.claude, .codex], project: project).failure, .accountMissing(.codex))
        XCTAssertEqual(ledger.activeLeases(pool: "team").count, 0)
    }

    func testTheEditorLineReadsBills() {
        XCTAssertEqual(RoundConfigEditor.billingLine(AccountBilling(text: "Team pool")), "Bills: Team pool")
        XCTAssertNil(RoundConfigEditor.billingLine(nil))
        XCTAssertEqual(AccountBilling.poolName("Night pool"), "Night pool", "never 'pool pool'")
    }

    // MARK: - The runner's lease lifecycle

    private final class Control: DaemonControlling {
        var liveSockets: Set<String> = []
        func isLive(_ id: UUID) -> Bool { false }
        func isLive(socketPath: String) -> Bool { liveSockets.contains(socketPath) }
        func daemonPID(_ id: UUID) -> pid_t? { nil }
        func daemonPID(socketPath: String) -> pid_t? { liveSockets.contains(socketPath) ? 4242 : nil }
        func terminate(_ id: UUID) {}
        func terminate(socketPath: String) { liveSockets.remove(socketPath) }
        func peerPID(socketPath: String) -> pid_t? { nil }
        func terminate(pid: pid_t, socketPath: String) { liveSockets.remove(socketPath) }
        func stop(_ id: UUID) {}
        func cont(_ id: UUID) {}
    }

    private final class Spawner: RunnerSpawning {
        var spawns = 0
        var error: Error?
        var onSpawn: (() -> Void)?
        func spawn(executable: String, arguments: [String], environment: [String: String]) throws {
            spawns += 1
            onSpawn?()
            if let error { throw error }
        }
    }

    private struct Rig {
        let controller: IntakeRunnerController
        let control: Control
        let spawner: Spawner
        let ledger: CapacityLedger
        let resolver: AccountResolver
        let intakesRoot: URL
        let id: UUID
        var directory: URL { IntakeStore(root: intakesRoot).directory(for: id) }
    }

    /// One shaping intake in `project` whose rounds run claude (pooled) and codex; `clock` drives
    /// the controller, so spawn grace and heartbeat freshness are under the test's control.
    private func rig(_ assignments: [AgentID: AccountAssignment] = [.claude: .pool("team")],
                     store: PreferencesStore? = nil, ledger: CapacityLedger? = nil,
                     control: Control = Control(), clock: @escaping () -> Date) throws -> Rig {
        let store = store ?? preferences(assignments)
        let ledger = ledger ?? self.ledger(for: store)
        let resolver = AccountResolver(preferences: store, ledger: ledger)
        let fakeBinary = tempDir.appendingPathComponent("fake-fd-abduco")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        let daemon = SessionDaemon(directory: tempDir.appendingPathComponent("daemon"), bundledBinary: fakeBinary)
        let intakesRoot = tempDir.appendingPathComponent("state/intakes")
        let spawner = Spawner()
        let controller = IntakeRunnerController(daemon: daemon, control: control, spawner: spawner,
                                                flightdeckPath: { "/fake/flightdeck" }, intakesRoot: intakesRoot,
                                                environment: { ["PATH": "/fake"] }, accounts: resolver, now: clock)
        let intakeStore = IntakeStore(root: intakesRoot)
        let id = intakeStore.all().first?.id ?? UUID()
        if intakeStore.all().isEmpty {
            var intake = Intake(projectPath: project, intent: "Add a thing")
            intake.id = id
            intake.state = .shaping
            let claudeB = ModelChoice(agent: .claude, model: "B", effort: "high")
            let codexA = ModelChoice(agent: .codex, model: "A", effort: "high")
            intake.roundConfig = RoundConfig(drafters: [Slot(codexA, fallback: claudeB)], synthesizer: nil, reviewer: nil,
                                             integrator: codexA, encoder: codexA, polisher: nil, refinementCap: 1,
                                             polishCap: 1, freshEyesAndDedup: false, defaultPlay: .step, customized: false)
            try intakeStore.save(intake)
        }
        return Rig(controller: controller, control: control, spawner: spawner, ledger: ledger, resolver: resolver,
                   intakesRoot: intakesRoot, id: id)
    }

    private func goLive(_ rig: Rig) { rig.control.liveSockets.insert(rig.controller.socketPath(for: rig.id)) }

    func testAStartLeasesAndRecordsEveryAgentAndANormalExitReleases() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let rig = try rig(clock: { now })
        rig.spawner.onSpawn = { self.goLive(rig) }
        XCTAssertNoThrow(try rig.controller.ensureRunning(rig.id).get())
        let file = try XCTUnwrap(RunnerAccounts.load(from: rig.directory))
        XCTAssertEqual(Set(file.agents.keys), [.claude, .codex], "the fallback's agent is resolved too")
        XCTAssertEqual(file.agents[.claude]?.accountID, work.id, "first under soft in Team")
        XCTAssertEqual(file.agents[.codex]?.accountID, codex.id, "no assignment: first live account")
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").count, 1)

        // The runner finishes; its daemon is gone.
        now += 60
        rig.control.liveSockets.removeAll()
        rig.controller.syncAccountLeases([rig.id])
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").count, 0)
    }

    /// A crash leaves the tape mid-round with a live socket but no heartbeat. Once out of spawn
    /// grace the runner reads as gone: its lease is released, and the respawn re-leases — the
    /// rollover point, which lands on Spare now that Work is over soft.
    func testACrashedRunnerReleasesAndItsRespawnRollsOver() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let rig = try rig(clock: { now })
        rig.spawner.onSpawn = { self.goLive(rig) }
        _ = rig.controller.ensureRunning(rig.id)
        XCTAssertEqual(RunnerAccounts.load(from: rig.directory)?.agents[.claude]?.accountID, work.id)

        overSoft(work, in: rig.ledger)
        now += 3_600
        rig.controller.syncAccountLeases([rig.id])
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").count, 0, "a dead runner holds nothing")

        XCTAssertNoThrow(try rig.controller.ensureRunning(rig.id).get())
        XCTAssertEqual(rig.spawner.spawns, 2)
        XCTAssertEqual(RunnerAccounts.load(from: rig.directory)?.agents[.claude]?.accountID, spare.id)
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").map(\.account.id), [spare.id])
    }

    func testAFailedSpawnReleasesItsLeases() throws {
        let rig = try rig(clock: { Date() })
        rig.spawner.error = FdAbducoRunnerSpawner.SpawnError.launcherFailed(1)
        guard case .failure(.spawnFailed) = rig.controller.ensureRunning(rig.id) else { return XCTFail("expected a spawn failure") }
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").count, 0)
    }

    func testAnUnresolvableAccountRefusesTheStartAndSpawnsNothing() throws {
        let rig = try rig([.codex: .account(UUID())], clock: { Date() })
        guard case .failure(.accountUnavailable(let why)) = rig.controller.ensureRunning(rig.id) else {
            return XCTFail("expected an account refusal")
        }
        XCTAssertTrue(why.contains("Codex account assigned to this project no longer exists"), why)
        XCTAssertEqual(rig.spawner.spawns, 0)
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").count, 0, "the claude lease taken first is handed back")
        XCTAssertNil(RunnerAccounts.load(from: rig.directory))
        XCTAssertEqual(IntakeService.describe(.accountUnavailable(why)), why)
    }

    /// The app quits with the runner alive under fd-abduco; the relaunched app's ledger is empty.
    /// The first tick re-registers the runner's lease from `accounts.json`, so the pool's books
    /// are right while it runs, and releases it when it exits.
    func testARelaunchAdoptsALiveRunnersLeasesAndReleasesThemWhenItExits() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let control = Control()
        let first = try rig(control: control, clock: { now })
        first.spawner.onSpawn = { self.goLive(first) }
        _ = first.controller.ensureRunning(first.id)
        let leased = try XCTUnwrap(RunnerAccounts.load(from: first.directory)?.leases.first)

        // Relaunch: a new controller and an empty ledger; the runner keeps beating.
        now += 600
        let store = preferences([.claude: .pool("team")])
        let relaunched = try rig(store: store, ledger: ledger(for: store), control: control, clock: { now })
        try TapeStore(intakeDirectory: relaunched.directory).saveTape(Tape(status: .running, heartbeat: now))
        XCTAssertEqual(relaunched.ledger.activeLeases(pool: "team").count, 0)
        relaunched.controller.syncAccountLeases([relaunched.id])
        XCTAssertEqual(relaunched.ledger.activeLeases(pool: "team"), [leased])
        // Adopting twice never double-counts.
        relaunched.controller.syncAccountLeases([relaunched.id])
        XCTAssertNoThrow(try relaunched.controller.ensureRunning(relaunched.id).get())
        XCTAssertEqual(relaunched.ledger.activeLeases(pool: "team").count, 1)
        XCTAssertEqual(relaunched.spawner.spawns, 0, "a live runner is adopted, not respawned")

        control.liveSockets.removeAll()
        relaunched.controller.syncAccountLeases([relaunched.id])
        XCTAssertEqual(relaunched.ledger.activeLeases(pool: "team").count, 0)
    }

    /// An intake that stopped shaping (finished, discarded) still hands its lease back.
    func testLeasesOfARunnerNoLongerShapingAreStillReleased() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let rig = try rig(clock: { now })
        rig.spawner.onSpawn = { self.goLive(rig) }
        _ = rig.controller.ensureRunning(rig.id)
        now += 60
        rig.control.liveSockets.removeAll()
        rig.controller.syncAccountLeases([])
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").count, 0)
    }

    /// `reap` (release review collecting a finished runner) releases at once.
    func testReapReleases() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let rig = try rig(clock: { now })
        rig.spawner.onSpawn = { self.goLive(rig) }
        _ = rig.controller.ensureRunning(rig.id)
        now += 3_600
        rig.controller.reap(rig.id)
        XCTAssertEqual(rig.ledger.activeLeases(pool: "team").count, 0)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { f } else { nil } }
}
