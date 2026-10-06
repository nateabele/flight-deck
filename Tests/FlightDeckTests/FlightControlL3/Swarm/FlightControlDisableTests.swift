import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §9. Turning Flight Control off stops FD acting on the repo and gives back what FD took;
/// it never edits the repo. Removing it from the repo is separate, shows what it will change, and
/// never touches `.beads`.
@MainActor
final class FlightControlDisableTests: XCTestCase {
    private var repo: URL!
    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("fc-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".beads"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: repo.appendingPathComponent(".beads/beads.db"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    private func service(_ rig: SwarmRig, agents: [SwarmAgentRecord]) async -> SwarmService {
        rig.store.save([rig.record(state: .paused, agents: agents)])
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        service.dependencies = SwarmDependencies(makeRouter: { [router = rig.router] in router }, kinds: rig.kinds, allocator: rig.allocator, capacity: rig.capacity)
        await service.settle()
        return service
    }

    /// The closed task belongs to a WORKING agent: reconcile-after-restart clears a pending claim
    /// before turnOff runs, so a pending claim would never reach turnOff's skip-closed branch.
    func testTurnOffStopsTheSwarmAndReturnsOnlyUnclosedClaims() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        let b = rig.agent("RedStone", state: .working, task: "fx-2")
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        rig.backend.statuses["fx-2"] = TaskStatusReading(status: "closed", assignee: "RedStone")
        let service = await service(rig, agents: [a, b])
        let reopened = await service.turnOff(project: SwarmFixtures.project)
        XCTAssertEqual(reopened, ["fx-1"])
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        XCTAssertEqual(service.record(forProject: SwarmFixtures.project)?.state, .stopped)
    }

    /// An unreadable status is not "not closed": it must never reopen, and a failed reopen is not done.
    func testAnUnreadableStatusNeverReopensAndAFailedReopenIsNotReported() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        let b = rig.agent("RedStone", state: .working, task: "fx-2")
        let c = rig.agent("GreenFox", state: .working, task: "fx-3")
        rig.backend.statuses["fx-2"] = TaskStatusReading(status: "in_progress", assignee: "RedStone")
        rig.backend.statuses["fx-3"] = TaskStatusReading(status: "in_progress", assignee: "GreenFox")
        rig.backend.returnToOpenFails = ["fx-3"]
        let service = await service(rig, agents: [a, b, c])
        let reopened = await service.turnOff(project: SwarmFixtures.project)
        XCTAssertEqual(reopened, ["fx-2"])
        XCTAssertEqual(rig.backend.returned, ["fx-2"])
    }

    func testOffReleasesEveryBootedAgentStopsWatchingAndClearsTheFlag() async {
        let rig = SwarmRig()
        var stopped: [String] = []
        var flag: [String: Bool] = [:]
        let off = FlightControlOff(swarm: nil, backend: rig.backend,
                                   agents: { _ in [(UUID(), "BlueLake"), (UUID(), "GreenFox")] },
                                   stopObserving: { stopped.append($0) },
                                   setEnabled: { flag[$0] = $1 })
        let report = await off.run(project: "/tmp/p/")
        XCTAssertEqual(report, FlightControlOff.Report(reopened: [], released: ["BlueLake", "GreenFox"]))
        XCTAssertEqual(rig.backend.released, ["BlueLake", "GreenFox"])
        XCTAssertEqual(stopped, ["/tmp/p"])
        XCTAssertEqual(flag, ["/tmp/p": false])
    }

    func testTheStoreTurnsTheProjectOff() async {
        let preferences = PreferencesStore(persistence: nil)
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences,
                                 flywheelObserveReads: FlywheelReadCommands(runner: MultiRunner()))
        var settings = preferences.projectSettings(repo.path); settings.flywheelEnabled = true
        preferences.setProjectSettings(repo.path, settings)
        _ = await store.turnOffFlightControl(project: repo.path)
        XCTAssertNotEqual(preferences.projectSettings(repo.path).flywheelEnabled, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads/beads.db").path),
                      "turning off never edits the repo")
    }

    func testRemovalListsAndRemovesOnlyWhatFlightDeckWrote() async throws {
        let hook = FlywheelSetup.beadsSyncHookPath(in: repo)
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FlywheelSetup.beadsSyncHookContents.write(to: hook, atomically: true, encoding: .utf8)
        let section = FlightControlRepoRemoval.agentsSectionStart + "\nUse br.\n"
            + (FlightControlRepoRemoval.agentsSectionEnd.map { $0 + "\n" } ?? "")
        try ("# Mine\n\nKeep this.\n\n" + section).write(to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let fake = MultiRunner(); fake.responses["am guard uninstall"] = ("", 0)
        let removal = FlightControlRepoRemoval(runner: fake)

        let planned = removal.plannedChanges(repo: repo)
        XCTAssertTrue(planned.contains("Delete the task-sync commit hook"))
        XCTAssertTrue(planned.contains("Remove the task-tracker section from AGENTS.md"))
        XCTAssertEqual(planned.last, "Keep the task data in the repo")

        _ = await removal.remove(repo: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hook.path))
        let agents = try String(contentsOf: repo.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(agents.contains("Keep this."))
        XCTAssertFalse(agents.contains(FlightControlRepoRemoval.agentsSectionStart))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads/beads.db").path))
    }

    func testAHookSomeoneElseEditedIsLeftAlone() async throws {
        let hook = FlywheelSetup.beadsSyncHookPath(in: repo)
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho mine\n".write(to: hook, atomically: true, encoding: .utf8)
        let removal = FlightControlRepoRemoval(runner: MultiRunner())
        XCTAssertFalse(removal.plannedChanges(repo: repo).contains("Delete the task-sync commit hook"))
        _ = await removal.remove(repo: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hook.path))
    }

    /// After a relaunch with no routing dependencies there is no controller, but the record still
    /// names the claims; Turn Off must still give them back and end the swarm.
    func testTurnOffWorksWithoutAController() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        rig.store.save([rig.record(state: .running, agents: [a])])
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        XCTAssertNil(service.controller(forProject: SwarmFixtures.project))
        let reopened = await service.turnOff(project: SwarmFixtures.project)
        XCTAssertEqual(reopened, ["fx-1"])
        XCTAssertEqual(service.record(forProject: SwarmFixtures.project)?.state, .stopped)
        XCTAssertEqual(rig.store.load().first?.state, .stopped, "and a later relaunch does not bring it back")
    }

    /// Probed: `br agents --remove --force` backs AGENTS.md up to AGENTS.md.bak and leaves it in
    /// the user's repo. A backup FD's own removal created is FD's to clean up.
    func testBrAgentsRemovalLeavesNoBackupBehind() async throws {
        try writeAgentsSection()
        let removal = FlightControlRepoRemoval(runner: BrAgentsRemoveStub())
        let done = await removal.remove(repo: repo)
        XCTAssertTrue(done.contains("agents"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("AGENTS.md.bak").path))
    }

    func testABackupThatWasAlreadyThereIsLeftAlone() async throws {
        try writeAgentsSection()
        try "mine".write(to: repo.appendingPathComponent("AGENTS.md.bak"), atomically: true, encoding: .utf8)
        let done = await FlightControlRepoRemoval(runner: BrAgentsRemoveStub()).remove(repo: repo)
        XCTAssertTrue(done.contains("agents"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("AGENTS.md.bak").path))
    }

    private func writeAgentsSection() throws {
        let section = FlightControlRepoRemoval.agentsSectionStart + "\nUse br.\n"
            + (FlightControlRepoRemoval.agentsSectionEnd.map { $0 + "\n" } ?? "")
        try ("# Mine\n\n" + section).write(to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    }
}

/// `br agents --remove --force` as probed: AGENTS.md is copied to AGENTS.md.bak, then the section
/// is removed. Every other command is "not found".
private final class BrAgentsRemoveStub: FlywheelProcessRunner, @unchecked Sendable {
    func run(_ executable: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        guard executable == "br", args == ["agents", "--remove", "--force"], let cwd else { return ("", 127) }
        let agents = URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.md")
        let text = try String(contentsOf: agents, encoding: .utf8)
        try text.write(to: URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.md.bak"), atomically: true, encoding: .utf8)
        try "# Mine\n".write(to: agents, atomically: true, encoding: .utf8)
        return ("", 0)
    }
}
