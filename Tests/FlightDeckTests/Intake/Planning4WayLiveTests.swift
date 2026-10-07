import XCTest
import IntakeKit
@testable import FlightDeck

/// One real planning round with all four model families seated at once (grok/gemini spec §5,
/// "One real Refine round"): claude and codex draft, Grok reviews, Gemini cross-checks, and
/// claude integrates. Every other rounds test scripts the harness replies, and the per-harness
/// live tests run one CLI alone; only this proves the four harnesses work TOGETHER through the
/// real `RoundExecutor` — parallel seats in one project, the blind cross-check merge, the
/// coverage reading over two new families — and that each seat's session resumes as its own.
///
/// Shape, and why: a Refine round needs a plan to refine, so a Draft round runs first (claude +
/// codex drafters). Refine round 1 is cross-checked, which is what seats a second reviewer — so
/// Grok (primary reviewer) and Gemini (cross-reviewer) each get a role and each produce a
/// `ReviewOutput` the round decodes. The executor runs every reviewer fresh on purpose (see
/// `refine`), so the "second round resumes each seat's own session" check is a direct resumed
/// turn per seat afterwards: it must come back on the SAME session id, and must recall the
/// project the seat was shown — which the resume prompt never names.
///
/// Models are what detection offers (the Rounds editor's defaults), not cheap ones: this is the
/// configuration Nate will actually run. That costs real tokens and many minutes, so it is
/// skipped unless `FLIGHTDECK_PLANNING_4WAY_LIVE=1` — run it by hand, ONCE, through
/// `FD_TEST_FILTER=Planning4WayLiveTests` (`test-unit.sh` hands its environment to `xctest`).
/// Never loop it; re-run only after a fix aimed at a specific failure. Set
/// `FLIGHTDECK_PLANNING_4WAY_KEEP=<dir>` to keep the intake's checkpoints and `runs/`.
///
/// `FLIGHTDECK_PLANNING_4WAY_FAMILIES=3` runs the same round WITHOUT the Gemini cross-check
/// (claude + codex drafting, Grok reviewing, claude integrating). That proves validation,
/// resume and Grok end to end while Gemini is unavailable, so only Gemini's part is left for
/// the four-family run. It is a run-time override only; the default is all four.
///
/// The intake is synthetic (a temperature-conversion CLI that does not exist), in a scratch
/// project under `$HOME` (never `/tmp`: `am` treats temp paths as ephemeral), removed on every
/// path, pass or fail.
final class Planning4WayLiveTests: XCTestCase {
    private var scratch: URL!
    private var environment: [String: String] = [:]

    private var project: URL { scratch.appendingPathComponent("project", isDirectory: true) }
    private var intakes: URL { scratch.appendingPathComponent("intakes", isDirectory: true) }

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLIGHTDECK_PLANNING_4WAY_LIVE"] == "1" else {
            throw XCTSkip("4-way planning round: set FLIGHTDECK_PLANNING_4WAY_LIVE=1 to spend real tokens on it")
        }
        // grok and agy install into ~/.local/bin, which an xctest process's PATH may lack.
        var path = env["PATH"] ?? "/usr/bin:/bin"
        for extra in [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
                      "/opt/homebrew/bin"] where !path.split(separator: ":").contains(Substring(extra)) {
            path += ":" + extra
        }
        environment = env
        environment["PATH"] = path
        guard Self.onPath("br", environment) != nil else { throw XCTSkip("br is not on PATH") }

        scratch = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fd-planning-4way-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("""
            # tempconv

            A tiny command-line tool that converts temperatures:
            `tempconv 100 c f` prints `212.0`. Units are c, f and k.
            It is a single Python file, `tempconv.py`, with no dependencies.

            """.utf8).write(to: project.appendingPathComponent("README.md"))
        try await sh("git", ["init", "-q"])
        try await sh("br", ["init"])
        try await sh("br", ["create", "--title", "Reject temperatures below absolute zero with a clear error",
                            "-t", "task", "-p", "2", "--description", "Today -500 c k prints a negative kelvin.", "--json"])
        try await sh("br", ["create", "--title", "Add a --precision flag for the number of decimals",
                            "-t", "task", "-p", "3", "--description", "Output is always one decimal place today.", "--json"])
    }

    override func tearDown() async throws {
        guard let scratch else { return }
        if let keep = ProcessInfo.processInfo.environment["FLIGHTDECK_PLANNING_4WAY_KEEP"] {
            let dest = URL(fileURLWithPath: keep, isDirectory: true)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: intakes, to: dest)
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    func testFourFamilyRefineRound() async throws {
        // Detection exactly as the app runs it: PATH, the sign-in check, the listed models.
        let available = TriageSettings.available(path: environment["PATH"])
        let claude = try XCTUnwrap(available.choice(for: .claude), "claude not offered")
        let codex = try XCTUnwrap(available.choice(for: .codex), "codex not offered")
        let grok = try XCTUnwrap(available.choice(for: .grok),
                                 "grok not offered: \(available.unavailable[.grok] ?? "not in headlessReady")")
        let withGemini = environment["FLIGHTDECK_PLANNING_4WAY_FAMILIES"] != "3"
        let gemini = withGemini ? try XCTUnwrap(available.choice(for: .gemini),
                                                "gemini not offered: \(available.unavailable[.gemini] ?? "not in headlessReady")") : nil
        print("planning-4way: seats claude \(claude.model)/\(claude.effort), codex \(codex.model)/\(codex.effort), "
              + "grok \(grok.model)/\(grok.effort), gemini \(gemini.map { "\($0.model)/\($0.effort)" } ?? "off")")

        var intake = Intake(projectPath: project.path,
                            intent: "Make tempconv safe for scripts: reject impossible temperatures and let callers choose the precision.")
        intake.state = .shaping
        let config = RoundConfig(drafters: [Slot(claude), Slot(codex)], synthesizer: nil, reviewer: Slot(grok),
                                 integrator: claude, encoder: claude, polisher: nil, refinementCap: 1, polishCap: 0,
                                 freshEyesAndDedup: false, defaultPlay: .toReview, customized: true,
                                 crossReviewer: gemini.map { Slot($0) }, crossCheck: withGemini ? .firstAndLast : .off)
        if withGemini { XCTAssertTrue(config.crossChecks, "Grok and Gemini must count as different families") }
        intake.roundConfig = config
        try IntakeStore(root: intakes).save(intake)
        let store = TapeStore(intakeDirectory: IntakeStore(root: intakes).directory(for: intake.id))
        var tape = store.loadTape()

        let commands = SystemCommandRunner()
        let executor = RoundExecutor(runner: commands, graphReader: GraphReader(runner: commands, environment: environment))
        let started = Date()

        // Draft: claude + codex in parallel.
        let draft = try await executor.run(PlannedRound(stage: .draft, round: 1, major: false),
                                           RoundInputs(intake: intake, config: config, tape: tape, store: store,
                                                       project: project, environment: environment))
        let draftCP = try landed(draft, "draft", store, &tape)
        Self.printSlots(draftCP, store)

        // Refine 1, cross-checked: Grok and Gemini review the same plan at once, claude integrates.
        let refine = try await executor.run(PlannedRound(stage: .refine, round: 1, major: false, crossCheck: withGemini),
                                            RoundInputs(intake: intake, config: config, tape: tape, store: store,
                                                        project: project, environment: environment))
        let refineCP = try landed(refine, "refine", store, &tape)
        Self.printSlots(refineCP, store)
        print("planning-4way: both rounds took " + String(format: "%.0f s", Date().timeIntervalSince(started)))

        // Every seat ran on what it was given and came back as decoded, schema-valid output:
        // `.ok` is only recorded after `RoundPrompts.decode` accepted the answer.
        let slots = draftCP.record.slots + refineCP.record.slots
        var seated: [(String, Harness)] = [("drafter", .claude), ("drafter", .codex), ("reviewer", .grok), ("integrator", .claude)]
        if withGemini { seated.append(("crossReviewer", .gemini)) }
        for (role, harness) in seated {
            let slot = slots.first { $0.role == role && $0.requested.harness == harness }
            XCTAssertEqual(slot?.status, .ok, "\(role) \(harness): \(String(describing: slot?.diagnosis))")
            XCTAssertEqual(slot?.used.harness, harness, "\(role) \(harness) fell back")
        }
        // A schema repair would mean the native `--json-schema` path did not hold.
        let repairs = Self.runDirectories(store).map(\.lastPathComponent).filter { $0.hasSuffix("-repair") }
        XCTAssertEqual(repairs, [], "schema repairs ran")

        // Coverage: four families seated, and the cross-check reading is Grok vs Gemini.
        let families = Set(slots.filter { $0.status == .ok }.map { ModelFamily($0.used.harness) })
        XCTAssertEqual(families, withGemini ? [.claude, .codex, .grok, .gemini] : [.claude, .codex, .grok])
        if withGemini { try assertCoverage(refineCP, store, tape) }

        // Resume: each read-only seat's own session, once. The integrator is write mode, which
        // never resumes (`resumeNotSupportedForWrite`).
        var sessions: [Harness: String] = [:]
        for (role, harness) in seated where role != "integrator" {
            guard let slot = slots.first(where: { $0.role == role && $0.used.harness == harness }),
                  let session = slot.sessionID else {
                XCTFail("\(role) \(harness) recorded no session")
                continue
            }
            sessions[harness] = session
            let resumed = try await resume(slot.used, session: session)
            print("planning-4way: resume \(harness.rawValue) \(resumed.seconds) s, tokens \(resumed.tokens), "
                  + "same session \(resumed.sessionID == session), recall: \(resumed.recall.prefix(120))")
            XCTAssertEqual(resumed.sessionID, session, "\(harness) resumed a different session")
            XCTAssertTrue(resumed.recall.lowercased().contains("temperat"),
                          "\(harness) resumed without its own context: \(resumed.recall)")
        }
        XCTAssertEqual(Set(sessions.values).count, sessions.count, "two seats shared a session: \(sessions)")
    }

    /// The cross-checked round's coverage: its record names Grok and Gemini, and the reading
    /// counts them as two families.
    private func assertCoverage(_ refineCP: Checkpoint, _ store: TapeStore, _ tape: Tape) throws {
        let crossRecord = try XCTUnwrap(try? IntakeJSON.decoder.decode(
            CrossCheckRecord.self,
            from: Data(contentsOf: store.checkpointDirectory(refineCP.id).appendingPathComponent(CrossCheckRecord.fileName))),
            "no crosscheck.json: did both reviewers propose nothing?")
        XCTAssertEqual(crossRecord.families, [.grok, .gemini])
        let readings = CoverageSeries.readings(tape.checkpoints) { id, name in
            try? Data(contentsOf: store.checkpointDirectory(id).appendingPathComponent(name))
        }
        if let reading = readings.last {
            print("planning-4way: coverage \(reading.familyA.displayName) vs \(reading.familyB.displayName): "
                  + "n1 \(reading.n1) n2 \(reading.n2) both \(reading.both) found \(reading.found) "
                  + "unfound \(reading.unfound.map(String.init) ?? "-") band \(reading.band.rawValue)")
            XCTAssertNotEqual(reading.familyA, reading.familyB, "coverage read the round as one family")
        } else {
            XCTFail("no coverage reading from the cross-checked round")
        }

    }

    // MARK: - Helpers

    private func landed(_ result: RoundResult, _ stage: String, _ store: TapeStore, _ tape: inout Tape) throws -> Checkpoint {
        switch result {
        case .checkpoint(let cp, let files):
            try store.writeCheckpoint(cp, files: files, into: &tape)
            return cp
        case .paused(let diagnosis, let partial):
            Self.printRuns(store)
            let slots = partial.slots.map { "\($0.role)=\($0.used.harness.rawValue):\($0.status) \($0.diagnosis.map { "\($0)" } ?? "")" }
            XCTFail("\(stage) round paused: \(diagnosis) — \(slots)")
            throw XCTSkip("stopping after the paused \(stage) round")
        }
    }

    /// One resumed turn on `session`, read-only, with the draft schema (a single `plan` string):
    /// the prompt never names the project, so recalling it proves the conversation carried over.
    private func resume(_ choice: ModelChoice, session: String) async throws
        -> (sessionID: String, recall: String, seconds: Int, tokens: String) {
        let dir = scratch.appendingPathComponent("resume-\(choice.harness.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schemaFile = dir.appendingPathComponent("schema.json")
        try Data(RoundSchemas.draft.utf8).write(to: schemaFile)
        let request = HarnessRequest(harness: choice.harness, model: choice.model, effort: choice.effort, cwd: project,
                                     readableDirs: [], prompt: "In one sentence, what does the tool in the project you "
                                        + "just worked on do? Put that sentence in `plan`.",
                                     schemaFile: schemaFile, schemaJSON: RoundSchemas.draft, resumeSessionID: session,
                                     account: choice.account)
        let command = try HarnessCommand.build(request)
        let started = Date()
        let result = try await SystemCommandRunner().run(
            executable: command.executable, arguments: command.arguments, cwd: project,
            environment: HarnessCommand.environment(for: command, base: environment, account: choice.account))
        try result.stdout.write(to: dir.appendingPathComponent("stdout"))
        XCTAssertEqual(result.exitCode, 0, "\(choice.harness) resume stderr: \(result.stderr.suffix(400))")
        let parsed = try HarnessOutput.parse(choice.harness, stdout: result.stdout)
        let object = try JSONSerialization.jsonObject(with: parsed.structured) as? [String: Any]
        return (parsed.sessionID, object?["plan"] as? String ?? "",
                Int(Date().timeIntervalSince(started)), Self.tokens(choice.harness, result.stdout))
    }

    private func sh(_ executable: String, _ arguments: [String]) async throws {
        let result = try await SystemCommandRunner().run(executable: executable, arguments: arguments,
                                                         cwd: project, environment: environment)
        guard result.exitCode == 0 else {
            throw NSError(domain: "Planning4Way", code: Int(result.exitCode), userInfo: [
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

    /// Input/output tokens (and cost when the CLI states one), folded from the seat's own
    /// stream by the same parser the planning UI uses.
    private static func tokens(_ harness: Harness, _ stdout: Data) -> String {
        var parser = ActivityParser(harness: harness, project: URL(fileURLWithPath: "/"), now: { Date() })
        parser.feed(stdout + Data("\n".utf8))
        let a = parser.activity
        let cost = a.costUSD.map { String(format: " $%.3f", $0) } ?? ""
        return "in \(a.inputTokens.map(String.init) ?? "-") out \(a.outputTokens.map(String.init) ?? "-")\(cost)"
    }

    /// One line per seat — the evidence the report records: role, what ran, outcome, duration,
    /// tokens, and the session it can be resumed on.
    private static func printSlots(_ cp: Checkpoint, _ store: TapeStore) {
        let prefix = "\(cp.stage.rawValue)-\(cp.round)-"
        let runs = runDirectories(store).filter { $0.lastPathComponent.hasPrefix(prefix) }
        for slot in cp.record.slots {
            let candidates = runs.filter { $0.lastPathComponent.hasPrefix(prefix + slot.role) }
            let run = candidates.first { dir in
                let record = (try? Data(contentsOf: dir.appendingPathComponent("run.json")))
                    .flatMap { try? IntakeJSON.decoder.decode(RunRecord.self, from: $0) }
                return slot.sessionID == nil || record?.sessionID == slot.sessionID
            } ?? candidates.first
            var seconds = "-", tokens = "-"
            if let run {
                if let data = try? Data(contentsOf: run.appendingPathComponent("run.json")),
                   let record = try? IntakeJSON.decoder.decode(RunRecord.self, from: data), let finished = record.finished {
                    seconds = String(format: "%.0f s", finished.timeIntervalSince(record.started))
                }
                if let stdout = try? Data(contentsOf: run.appendingPathComponent("stdout")) {
                    tokens = Self.tokens(slot.used.harness, stdout)
                }
            }
            print("planning-4way: \(cp.stage.rawValue) \(slot.role) \(slot.used.harness.rawValue) "
                  + "\(slot.used.model)/\(slot.used.effort) \(slot.status) \(seconds) \(tokens) "
                  + "run \(run?.lastPathComponent ?? "-") \(slot.diagnosis.map { "— \($0.category): \($0.detail)" } ?? "")")
        }
    }

    private static func printRuns(_ store: TapeStore) {
        for run in runDirectories(store) {
            let stderr = (try? String(contentsOf: run.appendingPathComponent("stderr"), encoding: .utf8)) ?? ""
            print("planning-4way:   \(run.lastPathComponent): stderr \(stderr.suffix(300))")
        }
    }
}
