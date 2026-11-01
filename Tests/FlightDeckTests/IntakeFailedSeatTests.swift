import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

@MainActor
private final class IdleRunnerController: IntakeRunnerControlling {
    var socketDirectory: URL = FileManager.default.temporaryDirectory
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> { .success(()) }
    func isRunning(_ id: UUID, tape: Tape?) -> Bool { false }
    func reap(_ id: UUID) {}
    func socketPath(for id: UUID) -> String {
        socketDirectory.appendingPathComponent("intake-\(id.uuidString.lowercased()).sock").path
    }
}

private final class NoProcessRunner: FlywheelProcessRunner, @unchecked Sendable {
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) { ("", 127) }
}

private final class NoHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) { (Data(), "", 1) }
}

/// The halt panel's failed seat on a tape exactly as the runner leaves it after a failure: status
/// `.failed`, NO `roundInProgress` (the runner clears it), and only `runs/<run>/` on disk to say
/// which seat failed. The seat feed reads nothing in that state, so `failedSeat` must read the
/// run files itself — before it did, a real failed polish round showed no output and no
/// "Retry with another model".
@MainActor
final class IntakeFailedSeatTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeFailedSeatTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testFailedSeatIsReadFromDiskWhenTheTapeHasNoRoundInProgress() async throws {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = .shaping
        i.recommended = .fullPlan
        i.chosenPreset = .fullPlan
        let config = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        i.roundConfig = config
        try IntakeStore(root: root).save(i)
        let store = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        var tape = store.loadTape()
        tape.status = .failed
        tape.failedAt = Date(timeIntervalSince1970: 1_800_000_100)
        tape.pauseDiagnosis = Diagnosis(category: .harnessError, detail: "network issue", action: "Retry, or change this slot.")
        XCTAssertNil(tape.roundInProgress)
        try store.saveTape(tape)

        let round = try XCTUnwrap(TapePlanner.upcoming(after: tape, config: config).first)
        let seat = try XCTUnwrap(RoundParticipants.of(round, config: config).first)
        let run = "\(round.stage.rawValue)-\(round.round)-" + seat.role + (seat.index.map { "-\($0)" } ?? "")
        let dir = store.runDirectory(run)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"action":{"object":"x","verb":"Searching"},"error":"There was a network issue connecting to the server, please try again.",
         "finished":true,"footprint":{},"harness":"gemini","lastEventAt":"2027-01-15T08:01:00.000Z","startedAt":"2027-01-15T08:00:00.000Z"}
        """.utf8).write(to: dir.appendingPathComponent("activity.json"))
        try Data(#"{"exitCode":3,"finished":"2027-01-15T08:01:00.000Z","pid":1,"started":"2027-01-15T08:00:00.000Z"}"#.utf8)
            .write(to: dir.appendingPathComponent("run.json"))
        try Data("AGY_ERROR: lookup daily-cloudcode-pa.googleapis.com: no such host\n".utf8)
            .write(to: dir.appendingPathComponent("stderr"))

        let runner = IdleRunnerController()
        runner.socketDirectory = root
        let svc = IntakeService(store: IntakeStore(root: root), headless: NoHeadlessRunner(), processRunner: NoProcessRunner(),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: runner,
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { Date(timeIntervalSince1970: 1_800_000_200) },
                                readFile: { try? Data(contentsOf: $0) }, announce: { _ in })
        await svc.launchRecovery?.value
        svc.pollTapes()

        let failed = try XCTUnwrap(svc.failedSeat(i.id), "the failed seat must be found from runs/ alone")
        XCTAssertEqual(failed.role, seat.role)
        XCTAssertTrue(failed.output?.contains("no such host") == true, "stderr tail feeds Show agent output")
    }
}
