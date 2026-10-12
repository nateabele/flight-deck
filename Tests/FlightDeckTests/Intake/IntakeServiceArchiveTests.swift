import XCTest
import IntakeKit
@testable import FlightDeck

@MainActor
private final class ArchiveFakeRunner: IntakeRunnerControlling {
    var running: Set<UUID> = []
    private(set) var ensured: [UUID] = []
    private(set) var reaped: [UUID] = []
    var socketDirectory: URL = FileManager.default.temporaryDirectory
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> { ensured.append(id); return .success(()) }
    func isRunning(_ id: UUID, tape: Tape?) -> Bool { running.contains(id) }
    func reap(_ id: UUID) { if !running.contains(id) { reaped.append(id) } }
    func socketPath(for id: UUID) -> String {
        socketDirectory.appendingPathComponent("intake-\(id.uuidString.lowercased()).sock").path
    }
}

/// Archive / Unarchive of a plan (the maintainer, 2026-10-12: "controls on the intake sidebar so I can at
/// least archive the existing one"). Soft: the files stay, the plan leaves the list, the phone's
/// plan list and the attention count, and comes back with Show Archived.
@MainActor
final class IntakeServiceArchiveTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var runner: ArchiveFakeRunner!
    private var clock: WatchClock!
    private var trashed: [URL] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeServiceArchiveTests-\(UUID())", isDirectory: true)
        suiteName = "IntakeServiceArchiveTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        runner = ArchiveFakeRunner()
        runner.socketDirectory = root
        clock = WatchClock(appIsActive: { false })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeService() -> IntakeService {
        IntakeService(store: IntakeStore(root: root),
                      triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                      availableModels: .defaults, clock: clock, runner: runner,
                      inject: { _, _, _, _ in true }, hasSession: { _, _ in false }, defaults: defaults,
                      trashItem: { [unowned self] url in
                          // A stand-in Trash: moved aside, so the intake directory really leaves.
                          let bin = self.root.deletingLastPathComponent()
                              .appendingPathComponent("trash-\(UUID())", isDirectory: true)
                          try FileManager.default.moveItem(at: url, to: bin)
                          self.trashed.append(url)
                      })
    }

    @discardableResult
    private func seed(_ intent: String, state: IntakeState = .review, at t: TimeInterval) throws -> UUID {
        var i = Intake(projectPath: "/p", intent: intent, createdAt: Date(timeIntervalSince1970: t))
        i.state = state
        if state == .shaping {
            i.chosenPreset = .featurePlan
            i.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        }
        try IntakeStore(root: root).save(i)
        return i.id
    }

    private func tapeStore(_ id: UUID) -> TapeStore {
        TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: id))
    }

    func testArchiveHidesPlanAndSurvivesRelaunch() throws {
        let id = try seed("larkOS", state: .needsAnswers, at: 1)
        let svc = makeService()
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1)

        XCTAssertTrue(svc.archive(id, inProject: "/p"))
        XCTAssertTrue(svc.isArchived(id))
        XCTAssertEqual(svc.intakes(forProject: "/p").map(\.id), [])
        XCTAssertEqual(svc.listedIntakes(forProject: "/p").map(\.id), [])
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 0, "an archived plan never badges")
        XCTAssertTrue(IntakeStore(root: root).isArchived(id: id))

        let relaunched = makeService()
        XCTAssertTrue(relaunched.isArchived(id))
        XCTAssertEqual(relaunched.intakes(forProject: "/p").map(\.id), [])

        relaunched.unarchive(id)
        XCTAssertFalse(relaunched.isArchived(id))
        XCTAssertEqual(relaunched.intakes(forProject: "/p").map(\.id), [id])
        XCTAssertFalse(IntakeStore(root: root).isArchived(id: id))
    }

    func testShowArchivedListsArchivedPlansAndPersists() throws {
        let old = try seed("old", at: 1)
        let new = try seed("new", at: 2)
        let svc = makeService()
        svc.archive(old, inProject: "/p")
        XCTAssertFalse(svc.showsArchived(forProject: "/p"))
        XCTAssertEqual(svc.listedIntakes(forProject: "/p").map(\.id), [new])

        svc.setShowsArchived(true, inProject: "/p")
        XCTAssertEqual(svc.listedIntakes(forProject: "/p").map(\.id), [new, old])
        // Shown, but still not an active plan: the phone and the badge keep ignoring it.
        XCTAssertEqual(svc.intakes(forProject: "/p").map(\.id), [new])
        XCTAssertTrue(makeService().showsArchived(forProject: "/p"))
    }

    func testArchivingTheSelectedPlanSelectsTheNextOne() throws {
        let a = try seed("a", at: 3)
        let b = try seed("b", at: 2)
        let c = try seed("c", at: 1)
        let svc = makeService()
        XCTAssertEqual(svc.listedIntakes(forProject: "/p").map(\.id), [a, b, c])

        svc.select(b, inProject: "/p")
        svc.archive(b, inProject: "/p")
        XCTAssertEqual(svc.selection(forProject: "/p"), c, "the plan below it")

        svc.archive(c, inProject: "/p")
        XCTAssertEqual(svc.selection(forProject: "/p"), a, "the last row falls back to the one above")

        svc.archive(a, inProject: "/p")
        XCTAssertNil(svc.selection(forProject: "/p"), "nothing left: the empty state")
    }

    func testArchivingAnUnselectedPlanKeepsTheSelection() throws {
        let a = try seed("a", at: 2)
        let b = try seed("b", at: 1)
        let svc = makeService()
        svc.select(a, inProject: "/p")
        svc.archive(b, inProject: "/p")
        XCTAssertEqual(svc.selection(forProject: "/p"), a)
    }

    func testArchivingWithShowArchivedOnKeepsTheSelection() throws {
        let a = try seed("a", at: 2)
        _ = try seed("b", at: 1)
        let svc = makeService()
        svc.setShowsArchived(true, inProject: "/p")
        svc.select(a, inProject: "/p")
        svc.archive(a, inProject: "/p")
        XCTAssertEqual(svc.selection(forProject: "/p"), a, "still listed, so still selected")
    }

    func testArchivingARunningPlanStopsItsRunnerFirst() async throws {
        let id = try seed("shaping", state: .shaping, at: 1)
        let svc = makeService()
        await svc.launchRecovery?.value
        var tape = tapeStore(id).loadTape()
        tape.status = .running
        try tapeStore(id).saveTape(tape)
        runner.running = [id]
        clock.fire()
        XCTAssertTrue(svc.isRoundRunning(id))

        XCTAssertTrue(svc.archive(id, inProject: "/p"))
        // The Stop control's own path: a stop command on the tape, and the halt it waits on.
        XCTAssertEqual(tapeStore(id).commands(after: 0).map(\.command), [.stop])
        XCTAssertEqual(svc.halts[id]?.kind, .stop)
        XCTAssertEqual(svc.intakes.first { $0.id == id }?.state, .shaping, "archive is not discard")

        // The daemon is collected once the runner has read the stop and exited (its account
        // leases go with it).
        tape = tapeStore(id).loadTape()
        tape.status = .stopped
        tape.ackedCommandSeq = 1
        try tapeStore(id).saveTape(tape)
        runner.running = []
        clock.fire()
        XCTAssertEqual(runner.reaped, [id])
    }

    func testArchivingAPausedPlanQueuesNoStop() async throws {
        let id = try seed("paused", state: .shaping, at: 1)
        let svc = makeService()
        await svc.launchRecovery?.value
        var tape = tapeStore(id).loadTape()
        tape.status = .paused
        try tapeStore(id).saveTape(tape)
        clock.fire()
        XCTAssertFalse(svc.isRoundRunning(id))
        XCTAssertTrue(svc.archive(id, inProject: "/p"))
        XCTAssertEqual(tapeStore(id).commands(after: 0).map(\.command), [])
    }

    func testDiscardedPlanCannotBeArchived() throws {
        let id = try seed("gone", at: 1)
        let svc = makeService()
        svc.discard(id)
        XCTAssertFalse(svc.canArchive(id))
        XCTAssertFalse(svc.archive(id, inProject: "/p"))
    }

    // MARK: Move to Trash

    func testMoveToTrashTrashesTheDirectoryAndSelectsTheNextPlan() throws {
        let a = try seed("a", at: 2)
        let b = try seed("b", at: 1)
        let svc = makeService()
        svc.select(a, inProject: "/p")
        XCTAssertTrue(svc.moveToTrash(a, inProject: "/p"))
        XCTAssertEqual(trashed, [IntakeStore(root: root).directory(for: a)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: IntakeStore(root: root).directory(for: a).path))
        XCTAssertEqual(svc.listedIntakes(forProject: "/p").map(\.id), [b])
        XCTAssertEqual(svc.selection(forProject: "/p"), b)
        XCTAssertEqual(makeService().intakes(forProject: "/p").map(\.id), [b], "gone after a relaunch too")
    }

    func testMoveToTrashOfAnArchivedPlan() throws {
        let id = try seed("a", at: 1)
        let svc = makeService()
        svc.archive(id, inProject: "/p")
        XCTAssertTrue(svc.moveToTrash(id, inProject: "/p"))
        XCTAssertFalse(svc.isArchived(id))
        XCTAssertEqual(trashed.count, 1)
    }

    /// Trashing the directory under a live runner would take the `commands.jsonl` it reads its
    /// stop from: the stop is queued, and the directory waits for the runner to exit.
    func testMoveToTrashOfARunningPlanWaitsForTheRunnerToStop() async throws {
        let id = try seed("shaping", state: .shaping, at: 1)
        let svc = makeService()
        await svc.launchRecovery?.value
        var tape = tapeStore(id).loadTape()
        tape.status = .running
        try tapeStore(id).saveTape(tape)
        runner.running = [id]
        clock.fire()

        XCTAssertTrue(svc.moveToTrash(id, inProject: "/p"))
        XCTAssertEqual(tapeStore(id).commands(after: 0).map(\.command), [.stop])
        XCTAssertEqual(svc.listedIntakes(forProject: "/p").map(\.id), [])
        XCTAssertTrue(IntakeStore(root: root).isArchived(id: id), "a quit before the trash relaunches it hidden")
        clock.fire()
        XCTAssertEqual(trashed, [], "runner still live")

        runner.running = []
        clock.fire()
        XCTAssertEqual(runner.reaped, [id])
        XCTAssertEqual(trashed, [IntakeStore(root: root).directory(for: id)])
    }
}
