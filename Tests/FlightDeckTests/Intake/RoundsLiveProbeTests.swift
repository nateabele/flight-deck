import XCTest
import IntakeKit

/// The one place real models meet the round prompts and schemas across a whole tape. Every
/// other rounds test scripts the harness replies, so they prove the executor handles the
/// shapes we EXPECT; only this proves a real codex/claude, given our prompts, produces a
/// draft, a review, an integrator edit and a change set that validates — the failure it
/// guards against is a schema or prompt the models can't satisfy, which no scripted test
/// can see.
///
/// Costs real tokens and minutes, so it is skipped unless `FLIGHTDECK_ROUNDS_LIVE=1` —
/// run it by hand, once, through `FD_TEST_FILTER=RoundsLiveProbeTests` (`test-unit.sh` hands
/// its own environment straight to `xctest`). Never loop it. Set
/// `FLIGHTDECK_ROUNDS_LIVE_KEEP=<dir>` to keep a copy of the intake's checkpoints and
/// `runs/` (every child's stdout/stderr) after the scratch project is removed.
/// `testCrossCheckRefineOverACopiedIntake` also needs `FLIGHTDECK_XCHECK_INTAKE` (see it).
///
/// The scratch project lives under `$HOME`, never `/tmp` (`am` treats temp paths as
/// ephemeral), and is removed on every path, pass or fail.
final class RoundsLiveProbeTests: XCTestCase {
    private var scratch: URL!
    private var environment: [String: String] = [:]

    private var project: URL { scratch.appendingPathComponent("project", isDirectory: true) }
    private var intakes: URL { scratch.appendingPathComponent("intakes", isDirectory: true) }

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLIGHTDECK_ROUNDS_LIVE"] == "1" else {
            throw XCTSkip("live rounds probe: set FLIGHTDECK_ROUNDS_LIVE=1 to spend real tokens on it")
        }
        guard Self.onPath("br", env) != nil else { throw XCTSkip("br is not on PATH") }
        // The runner's environment is built the way the app's will be — the process's own —
        // minus LoginShellPath's repair, which lives in the app target, not IntakeKit.
        environment = env
        scratch = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fd-rounds-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("# tallyho\n\nA tiny command-line todo list: `tallyho add <text>`, `tallyho list`.\n".utf8)
            .write(to: project.appendingPathComponent("README.md"))
        try await sh("git", ["init", "-q"])
        try await sh("br", ["init"])
        try await sh("br", ["create", "--title", "Add a `done <n>` command that marks an item complete",
                            "-t", "task", "-p", "2", "--description", "Items are stored one per line in ~/.tallyho.",
                            "--json"])
        try await sh("br", ["create", "--title", "Show completed items struck through in `list`",
                            "-t", "task", "-p", "3", "--description", "Depends on `done` existing.", "--json"])
    }

    override func tearDown() async throws {
        guard let scratch else { return }
        if let keep = ProcessInfo.processInfo.environment["FLIGHTDECK_ROUNDS_LIVE_KEEP"] {
            let dest = URL(fileURLWithPath: keep, isDirectory: true)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: intakes, to: dest)
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    func testSketchReachesReviewWithAValidChangeSet() async throws {
        // Cheap models: this probes prompt/schema fit, not plan quality.
        let seat = Self.onPath("codex", environment) != nil
            ? ModelChoice(agent: .codex, model: "gpt-5.6-luna", effort: "low")
            : ModelChoice(agent: .claude, model: "haiku", effort: "low")
        var intake = Intake(projectPath: project.path,
                            intent: "Add a `--json` flag to every tallyho command so scripts can read its output.")
        intake.chosenPreset = .sketch
        intake.state = .shaping
        intake.roundConfig = RoundConfig(drafters: [Slot(seat)], synthesizer: nil, reviewer: Slot(seat),
                                         integrator: seat, encoder: seat, polisher: nil, refinementCap: 1,
                                         polishCap: 0, freshEyesAndDedup: false, defaultPlay: .toReview,
                                         customized: true)
        try IntakeStore(root: intakes).save(intake)
        let store = TapeStore(intakeDirectory: IntakeStore(root: intakes).directory(for: intake.id))
        _ = try store.appendCommand(.toReview)

        let commands = SystemCommandRunner()
        let graphReader = GraphReader(runner: commands, environment: environment)
        let runner = IntakeRunner(root: intakes, intakeID: intake.id,
                                  executor: RoundExecutor(runner: commands, graphReader: graphReader),
                                  environment: environment)
        let started = Date()
        let status = await runner.run()
        let tape = store.loadTape()
        print("rounds-live: \(seat.agent.rawValue) \(seat.model)/\(seat.effort) → \(status) in "
              + String(format: "%.0f s", Date().timeIntervalSince(started)))
        Self.printRuns(store)

        XCTAssertEqual(status, .reachedReview, "paused: \(String(describing: tape.pauseDiagnosis))")
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft, .refine, .encode])
        let changeSetFile = try XCTUnwrap(tape.checkpoints.last.map {
            store.checkpointDirectory($0.id).appendingPathComponent("changeset.json")
        })
        let changeSet = try ChangeSet.decode(Data(contentsOf: changeSetFile))
        let graph = try await graphReader.read(project: project.path)
        if case .failure(let errors) = ChangeSetValidator.validate(changeSet, against: graph) {
            XCTFail("final change set does not validate: \(errors.errors.map(\.message))")
        }
        let runs = Self.runDirectories(store)
        XCTAssertFalse(runs.isEmpty)
        for run in runs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: run.appendingPathComponent("run.json").path),
                          "\(run.lastPathComponent) has no run.json")
        }
    }

    /// The first real data point for coverage (spec §4–§5): one cross-checked Refine round over
    /// a COPY of a real intake that has a synthesis checkpoint, so the numbers come from a real
    /// plan rather than tallyho. Point `FLIGHTDECK_XCHECK_INTAKE` at the copied intake directory —
    /// never the live one under Application Support: this writes `runs/`, `work/` and the new
    /// checkpoint into it, the way the runner would. The reviewers run read-only in the intake's
    /// real `projectPath`. Three expensive turns (both reviewers and the integrator at the
    /// intake's own models), so it runs once by hand and is never looped.
    func testCrossCheckRefineOverACopiedIntake() async throws {
        guard let path = environment["FLIGHTDECK_XCHECK_INTAKE"] else {
            throw XCTSkip("cross-check probe: set FLIGHTDECK_XCHECK_INTAKE to a COPIED intake directory")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let id = try XCTUnwrap(UUID(uuidString: dir.lastPathComponent), "the directory must be named for its intake id")
        let intake = try IntakeStore(root: dir.deletingLastPathComponent()).load(id: id)
        var config = try XCTUnwrap(intake.roundConfig)
        // No fallback, as the coverage spec requires: a cross-reviewer that fell back would be
        // the primary's family, and the round would measure nothing.
        config.crossReviewer = Slot(ModelChoice(agent: .claude, model: "opus", effort: "high"))
        config.crossCheck = .firstAndLast
        XCTAssertTrue(config.crossChecks, "reviewer and cross-reviewer must be different families")
        let store = TapeStore(intakeDirectory: dir)
        var tape = store.loadTape()

        let commands = SystemCommandRunner()
        let executor = RoundExecutor(runner: commands, graphReader: GraphReader(runner: commands, environment: environment))
        let inputs = RoundInputs(intake: intake, config: config, tape: tape, store: store,
                                 project: URL(fileURLWithPath: intake.projectPath, isDirectory: true),
                                 environment: environment)
        let started = Date()
        let result = try await executor.run(PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true), inputs)
        print("xcheck-live: round took " + String(format: "%.0f s", Date().timeIntervalSince(started)))
        Self.printRuns(store)
        guard case .checkpoint(let cp, let files) = result else {
            if case .paused(let diagnosis, let partial) = result {
                XCTFail("round paused: \(diagnosis) — slots \(partial.slots.map { "\($0.role):\($0.status)" })")
            }
            return
        }
        try store.writeCheckpoint(cp, files: files, into: &tape)
        print("xcheck-live: checkpoint \(cp.id) files \(files.keys.sorted()), slots "
              + cp.record.slots.map { "\($0.role)=\($0.used.agent.rawValue)/\($0.used.model):\($0.status)" }.joined(separator: " "))

        let readings = CoverageSeries.readings(tape.checkpoints) { id, name in
            try? Data(contentsOf: store.checkpointDirectory(id).appendingPathComponent(name))
        }
        let reading = try XCTUnwrap(readings.last, "no coverage reading — was crosscheck.json written?")
        let estimate = CoverageSeries.chapman(n1: reading.n1, n2: reading.n2, both: reading.both)
        print("xcheck-live: \(reading.familyA.rawValue) vs \(reading.familyB.rawValue), matcher \(reading.matcher.rawValue)")
        print("xcheck-live: n1 \(reading.n1)  n2 \(reading.n2)  both \(reading.both)  found \(reading.found)  "
              + String(format: "chapman %.1f", estimate) + "  unfound \(reading.unfound.map(String.init) ?? "-")")
        print("xcheck-live: band \(reading.band.rawValue)  correlated \(reading.correlated)  "
              + "textSimilarityBoth \(reading.textSimilarityBoth.map(String.init) ?? "-")  "
              + "matchersDisagree \(reading.matchersDisagree)  rejectedA \(reading.rejectedA)  rejectedB \(reading.rejectedB)")
        XCTAssertEqual(reading.checkpoint, cp.id)
    }

    // MARK: - Helpers

    private func sh(_ executable: String, _ arguments: [String]) async throws {
        let result = try await SystemCommandRunner().run(executable: executable, arguments: arguments,
                                                         cwd: project, environment: environment)
        guard result.exitCode == 0 else {
            throw NSError(domain: "RoundsLiveProbe", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed: "
                    + String(decoding: result.stdout, as: UTF8.self) + result.stderr])
        }
    }

    private static func onPath(_ name: String, _ env: [String: String]) -> String? {
        (env["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runDirectories(_ store: TapeStore) -> [URL] {
        let runs = store.intakeDirectory.appendingPathComponent("runs", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One line per child — the timing evidence the task report records.
    private static func printRuns(_ store: TapeStore) {
        for run in runDirectories(store) {
            guard let data = try? Data(contentsOf: run.appendingPathComponent("run.json")),
                  let record = try? IntakeJSON.decoder.decode(RunRecord.self, from: data) else {
                print("rounds-live:   \(run.lastPathComponent): no readable run.json")
                continue
            }
            let seconds = record.finished.map { String(format: "%.0f s", $0.timeIntervalSince(record.started)) } ?? "unfinished"
            print("rounds-live:   \(run.lastPathComponent): \(seconds), exit \(record.exitCode.map(String.init) ?? "-")")
        }
    }
}
