import XCTest
import IntakeKit

/// A `CommandRunner` that answers `br` with a canned graph and every harness child with
/// whatever `script` returns for it — the role is read off the prompt, since that is the one
/// thing every seat's argv carries in both harness shapes.
final class ScriptedHarnessRunner: CommandRunner, @unchecked Sendable {
    struct Call {
        var executable: String, arguments: [String], cwd: URL, environment: [String: String], processGroup: Bool
        var prompt: String {
            if executable == "claude", let i = arguments.firstIndex(of: "-p") { return arguments[i + 1] }
            return arguments.last ?? ""
        }
        var model: String? {
            guard let i = arguments.firstIndex(where: { $0 == "-m" || $0 == "--model" }) else { return nil }
            return arguments[i + 1]
        }
        var role: String {
            let p = prompt
            if p.contains("failed validation") { return "correction" }
            if p.contains("You are drafting") { return "drafter" }
            if p.contains("competing models") { return "synthesizer" }
            if p.contains("refinement round") { return "reviewer" }
            if p.contains("Integrate these revisions") { return "integrator" }
            if p.contains("Turn ALL of the plan") { return "encoder" }
            return "polisher"
        }
        /// codex's schema file lives in this call's `runs/<name>/`.
        var runDirectory: URL? {
            guard let i = arguments.firstIndex(of: "--output-schema") else { return nil }
            return URL(fileURLWithPath: arguments[i + 1]).deletingLastPathComponent()
        }
        var isResume: Bool { arguments.contains("resume") || arguments.contains("--resume") }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    func calls(_ role: String) -> [Call] { calls.filter { $0.executable != "br" && $0.role == role } }

    var graphList = #"{"issues":[{"id":"fd-1","title":"Existing","status":"open","labels":[]}]}"#
    var graphEdges = #"{"components":[{"edges":[]}]}"#
    var nextPID: Int32 = 4000
    let script: @Sendable (Call) -> CommandResult
    var onCall: (@Sendable (Call) -> Void)?

    init(_ script: @escaping @Sendable (Call) -> CommandResult) { self.script = script }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                        processGroup: processGroup)
        let pid: Int32 = lock.withLock { _calls.append(call); nextPID += 1; return nextPID }
        if executable == "br" {
            let out = arguments.first == "list" ? graphList : graphEdges
            return CommandResult(stdout: Data(out.utf8), stderr: "", exitCode: 0)
        }
        onCall?(call)
        onSpawn?(pid)
        return script(call)
    }
}

// MARK: - Harness-shaped outputs

func codexOK(_ session: String, _ json: String) -> CommandResult {
    let started = #"{"type":"thread.started","thread_id":"\#(session)"}"#
    let message = try! JSONSerialization.data(withJSONObject: ["type": "item.completed",
                                                               "item": ["type": "agent_message", "text": json]])
    return CommandResult(stdout: Data((started + "\n" + String(decoding: message, as: UTF8.self) + "\n").utf8),
                         stderr: "", exitCode: 0)
}

func claudeOK(_ session: String, _ json: String) -> CommandResult {
    let structured = try! JSONSerialization.jsonObject(with: Data(json.utf8))
    let out = try! JSONSerialization.data(withJSONObject: ["type": "result", "session_id": session,
                                                           "structured_output": structured])
    return CommandResult(stdout: out, stderr: "", exitCode: 0)
}

/// Answers in whichever shape the call's harness speaks.
func ok(_ call: ScriptedHarnessRunner.Call, _ session: String, _ json: String) -> CommandResult {
    call.executable == "claude" ? claudeOK(session, json) : codexOK(session, json)
}

func failed(_ stderr: String) -> CommandResult { CommandResult(stdout: Data(), stderr: stderr, exitCode: 1) }

func json<T: Encodable>(_ value: T) -> String { String(decoding: try! IntakeJSON.encoder.encode(value), as: UTF8.self) }

final class RoundExecutorTests: XCTestCase {
    let codexA = ModelChoice(harness: .codex, model: "A", effort: "high")
    let claudeB = ModelChoice(harness: .claude, model: "B", effort: "medium")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoundExecutorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var store: TapeStore { TapeStore(intakeDirectory: root.appendingPathComponent("intake")) }
    var project: URL { root.appendingPathComponent("project") }
    var work: URL { store.workDirectory() }

    func config(drafters: [Slot]? = nil, integrator: ModelChoice? = nil, polisher: ModelChoice? = nil) -> RoundConfig {
        RoundConfig(drafters: drafters ?? [Slot(codexA)], synthesizer: Slot(codexA, persona: .arbiter),
                    reviewer: Slot(claudeB), integrator: integrator ?? claudeB, encoder: codexA,
                    polisher: polisher ?? claudeB, refinementCap: 2, polishCap: 1, freshEyesAndDedup: false,
                    defaultPlay: .step, customized: false)
    }

    func inputs(_ config: RoundConfig, tape: Tape = Tape()) -> RoundInputs {
        let fixed = now
        return RoundInputs(intake: Intake(projectPath: project.path, intent: "Add dark mode"), config: config, tape: tape,
                           store: store, project: project,
                           environment: ["PATH": "/usr/bin:/bin", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1"],
                           now: { fixed })
    }

    func executor(_ runner: CommandRunner) -> RoundExecutor {
        RoundExecutor(runner: runner, graphReader: GraphReader(runner: runner, environment: [:]))
    }

    /// Writes a checkpoint's files the way the runner would, and appends it to `tape`.
    func seed(_ tape: inout Tape, _ stage: Stage, round: Int = 0, files: [String: String]) throws {
        let id = (tape.head?.id ?? 0) + 1
        let dir = store.checkpointDirectory(id)
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        tape.checkpoints.append(Checkpoint(id: id, parent: tape.head?.id, stage: stage, round: round, major: true,
                                           createdAt: now))
    }

    func checkpoint(_ r: RoundResult, file: StaticString = #filePath, line: UInt = #line) throws -> (Checkpoint, [String: Data]) {
        guard case .checkpoint(let cp, let files) = r else { XCTFail("expected a checkpoint, got \(r)", file: file, line: line); throw CancellationError() }
        return (cp, files)
    }
    func paused(_ r: RoundResult, file: StaticString = #filePath, line: UInt = #line) throws -> (Diagnosis, RoundRecord) {
        guard case .paused(let d, let rec) = r else { XCTFail("expected a pause, got \(r)", file: file, line: line); throw CancellationError() }
        return (d, rec)
    }
    func text(_ d: Data?) -> String? { d.map { String(decoding: $0, as: UTF8.self) } }

    let draftPlan = "# Plan\n\n## Scope\nOne\n"
    func review(_ n: Int) -> String {
        json(ReviewOutput(changes: (0..<n).map { ProposedChange(section: "## Scope", rationale: "r\($0)", edit: "add \($0)") },
                          summary: "found \(n)"))
    }

    /// The integrator appends a section to `work/plan.md` — really editing the file, as the
    /// real one would with Edit/Write.
    func editingIntegrator(_ call: ScriptedHarnessRunner.Call) -> CommandResult {
        let plan = call.cwd.appendingPathComponent("plan.md")
        let before = (try? String(contentsOf: plan, encoding: .utf8)) ?? ""
        try! (before + "\n## Added\nnew line\n").write(to: plan, atomically: true, encoding: .utf8)
        return ok(call, "int-1", json(IntegrateOutput(agree: 1, somewhat: 1, disagree: 0, notes: "applied")))
    }

    // MARK: - Draft

    func testDraftRoundWritesEachDraft() async throws {
        let runner = ScriptedHarnessRunner { call in ok(call, "s-\(call.model!)", json(DraftOutput(plan: "# From \(call.model!)"))) }
        let cfg = config(drafters: [Slot(codexA, persona: .arbiter), Slot(claudeB, persona: .realist)])
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true), inputs(cfg)))

        XCTAssertEqual(cp.id, 1); XCTAssertNil(cp.parent); XCTAssertEqual(cp.stage, .draft)
        XCTAssertEqual(text(files["drafts/0.md"]), "# From A")
        XCTAssertEqual(text(files["drafts/1.md"]), "# From B")
        XCTAssertEqual(cp.record.slots.map(\.status), [.ok, .ok])
        XCTAssertEqual(cp.record.slots.map(\.sessionID), ["s-A", "s-B"])
        XCTAssertEqual(cp.record.slots.map(\.persona), [.arbiter, .realist])
        let drafters = runner.calls("drafter")
        XCTAssertEqual(drafters.count, 2)
        for c in drafters {
            XCTAssertTrue(c.processGroup)
            XCTAssertEqual(c.cwd.standardizedFileURL, project.standardizedFileURL)
        }
        let claude = try XCTUnwrap(drafters.first { $0.executable == "claude" })
        XCTAssertTrue(claude.arguments.contains("--effort") && claude.arguments.contains("medium"))
        XCTAssertNil(claude.environment["CLAUDE_CODE_CHILD_SESSION"], "else claude skips saving its transcript")
        XCTAssertNil(claude.environment["CLAUDECODE"])
        XCTAssertEqual(claude.environment["PATH"], "/usr/bin:/bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("graph.json").path))
    }

    func testDrafterFallsBackOnce() async throws {
        let runner = ScriptedHarnessRunner { call in
            call.model == "A" ? failed("Error: 401 Unauthorized") : ok(call, "fb", json(DraftOutput(plan: "# Fallback")))
        }
        let cfg = config(drafters: [Slot(codexA, fallback: claudeB)])
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true), inputs(cfg)))
        XCTAssertEqual(text(files["drafts/0.md"]), "# Fallback")
        let slot = try XCTUnwrap(cp.record.slots.first)
        XCTAssertEqual(slot.status, .substituted)
        XCTAssertEqual(slot.requested, codexA)
        XCTAssertEqual(slot.used, claudeB)
        XCTAssertEqual(slot.sessionID, "fb")
        XCTAssertEqual(runner.calls("drafter").map(\.model), ["A", "B"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory("draft-0-drafter-0-fallback").appendingPathComponent("run.json").path))
    }

    func testAllDraftersFailPausesTape() async throws {
        let runner = ScriptedHarnessRunner { _ in failed("Error: 401 Unauthorized") }
        let cfg = config(drafters: [Slot(codexA, fallback: claudeB), Slot(claudeB, fallback: codexA)])
        let (d, rec) = try paused(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true), inputs(cfg)))
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(rec.slots.map(\.status), [.failed, .failed])
        XCTAssertEqual(runner.calls("drafter").count, 4, "each drafter plus its fallback, exactly once")
    }

    // MARK: - Synthesis / refine

    func synthesisTape() throws -> Tape {
        var tape = Tape()
        try seed(&tape, .draft, files: ["drafts/0.md": draftPlan, "drafts/1.md": "# Other"])
        return tape
    }

    func testSynthesisAppliesViaIntegratorAndCountsDelta() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "synthesizer": return ok(call, "syn-1", self.review(2))
            default: return self.editingIntegrator(call)
            }
        }
        let r = try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                               inputs(config(), tape: try synthesisTape()))
        let (cp, files) = try checkpoint(r)
        XCTAssertEqual(cp.id, 2); XCTAssertEqual(cp.parent, 1)
        XCTAssertEqual(text(files["plan.md"]), draftPlan + "\n## Added\nnew line\n")
        XCTAssertEqual(cp.record.linesAdded, 3)
        XCTAssertEqual(cp.record.linesRemoved, 0)
        XCTAssertFalse(cp.record.sectionsChanged.isEmpty)
        XCTAssertEqual(cp.record.changeCount, 2)
        XCTAssertEqual(cp.record.tally, VerdictTally(agree: 1, somewhat: 1, disagree: 0))
        XCTAssertEqual(cp.record.slots.map(\.role), ["synthesizer", "integrator"])
        XCTAssertEqual(cp.record.slots.map(\.sessionID), ["syn-1", "int-1"])

        let synth = try XCTUnwrap(runner.calls("synthesizer").first)
        XCTAssertEqual(synth.cwd.standardizedFileURL, project.standardizedFileURL)
        XCTAssertTrue(synth.prompt.contains(store.checkpointDirectory(1).appendingPathComponent("drafts/0.md").path))
        let integrator = try XCTUnwrap(runner.calls("integrator").first)
        XCTAssertEqual(integrator.cwd.standardizedFileURL, work.standardizedFileURL, "never the project")
        XCTAssertTrue(integrator.arguments.contains("acceptEdits"))
        let changes = try JSONDecoder().decode([ProposedChange].self, from: Data(contentsOf: work.appendingPathComponent("changes.json")))
        XCTAssertEqual(changes.count, 2)
    }

    func testIntegratorThatDidNotEditPausesWithDiagnosis() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "synthesizer" ? ok(call, "syn", self.review(2))
                : ok(call, "int", json(IntegrateOutput(agree: 2, somewhat: 0, disagree: 0, notes: "done")))
        }
        let (d, rec) = try paused(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                 inputs(config(), tape: try synthesisTape())))
        XCTAssertEqual(d.category, .invalidOutput)
        XCTAssertEqual(d.detail, "integrator reported changes but did not edit the plan")
        XCTAssertEqual(rec.slots.map(\.role), ["synthesizer", "integrator"])
        XCTAssertEqual(rec.slots.last?.status, .failed)
    }

    func testIntegratorThatDisagreedWithEverythingNeedNotEdit() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "synthesizer" ? ok(call, "syn", self.review(1))
                : ok(call, "int", json(IntegrateOutput(agree: 0, somewhat: 0, disagree: 1, notes: "no")))
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                        inputs(config(), tape: try synthesisTape())))
        XCTAssertEqual(text(files["plan.md"]), draftPlan)
        XCTAssertEqual(cp.record.linesAdded, 0)
    }

    func refineTape() throws -> Tape {
        var tape = try synthesisTape()
        try seed(&tape, .synthesis, files: ["plan.md": draftPlan])
        return tape
    }

    func testReviewerProseIsInvalidOutput() async throws {
        let runner = ScriptedHarnessRunner { call in
            call.role == "reviewer" ? codexOK("rev", "Sure! Here are my thoughts on the plan.") : failed("unreachable")
        }
        let cfg = { var c = self.config(); c.reviewer = Slot(self.codexA); return c }()
        let (d, rec) = try paused(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                 inputs(cfg, tape: try refineTape())))
        XCTAssertEqual(d.category, .invalidOutput)
        XCTAssertEqual(rec.slots.map(\.role), ["reviewer"])
        XCTAssertTrue(runner.calls("integrator").isEmpty)
    }

    func testRefineUsesFreshSessionEachRound() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "same-session", self.review(1)) : self.editingIntegrator(call)
        }
        var tape = try refineTape()
        let ex = executor(runner)
        for round in 1...2 {
            let (cp, files) = try checkpoint(try await ex.run(PlannedRound(stage: .refine, round: round, major: round == 2),
                                                             inputs(config(), tape: tape)))
            try seed(&tape, .refine, round: round, files: ["plan.md": text(files["plan.md"])!])
            XCTAssertEqual(cp.record.slots.first?.role, "reviewer")
        }
        let reviewers = runner.calls("reviewer")
        XCTAssertEqual(reviewers.count, 2)
        XCTAssertFalse(runner.calls.contains { $0.isResume }, "no reviewer or integrator may resume")
        // Round 2 reviews round 1's output, not the synthesis plan.
        XCTAssertTrue(reviewers[1].prompt.contains(store.checkpointDirectory(3).appendingPathComponent("plan.md").path))
    }

    func testRefineConsumesAnnotations() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "rev", self.review(1)) : self.editingIntegrator(call)
        }
        var tape = try refineTape()
        tape.pendingAnnotations = ["focus on auth"]
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                    inputs(config(), tape: tape)))
        XCTAssertEqual(cp.record.annotations, ["focus on auth"])
        XCTAssertTrue(try XCTUnwrap(runner.calls("reviewer").first).prompt.contains("focus on auth"))
    }

    func testSketchCurrentPlanIsDraftZero() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "rev", self.review(1)) : self.editingIntegrator(call)
        }
        var tape = Tape()
        try seed(&tape, .draft, files: ["drafts/0.md": draftPlan])
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                        inputs(config(), tape: tape)))
        let reviewer = try XCTUnwrap(runner.calls("reviewer").first)
        XCTAssertTrue(reviewer.prompt.contains(store.checkpointDirectory(1).appendingPathComponent("drafts/0.md").path))
        XCTAssertEqual(text(files["plan.md"]), draftPlan + "\n## Added\nnew line\n")
        XCTAssertEqual(cp.record.linesAdded, 3)
    }

    // MARK: - Encode / polish

    let existingPre = Precondition(status: "open", assignee: nil)
    func changeSetReply(pre: Precondition, extra: [ChangeOp] = [], observedAt: Date = Date(timeIntervalSince1970: 0)) -> String {
        json(ChangeSetOutput(changeSet: ChangeSet(graphObservedAt: observedAt,
                                                  ops: [.editBead(id: "fd-1", set: FieldSet(title: "Renamed"), pre: pre, delivery: nil)] + extra),
                             summary: "encoded"))
    }
    let newBead = ChangeOp.createBead(NewBead(tempId: "t1", title: "New", description: "d"))

    func testEncodeValidatesAndRetriesOnce() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "encoder" ? ok(call, "enc-1", self.changeSetReply(pre: Precondition(status: "closed", assignee: nil)))
                : ok(call, "enc-1", self.changeSetReply(pre: self.existingPre))
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .encode, round: 0, major: true),
                                                                        inputs(config(), tape: try refineTape())))
        let cs = try ChangeSet.decode(try XCTUnwrap(files["changeset.json"]))
        XCTAssertEqual(cs.graphObservedAt, now, "FD's clock, not the agent's")
        XCTAssertEqual(text(files["plan.md"]), draftPlan)
        XCTAssertEqual(cp.record.slots.map(\.status), [.ok])
        let correction = try XCTUnwrap(runner.calls("correction").first)
        XCTAssertEqual(runner.calls("correction").count, 1)
        XCTAssertEqual(Array(correction.arguments.prefix(2)), ["exec", "resume"])
        XCTAssertTrue(correction.arguments.contains("enc-1"))
        XCTAssertTrue(correction.arguments.contains("model_reasoning_effort=high") && correction.model == "A")
        XCTAssertTrue(correction.prompt.contains("fd-1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("graph.json").path))
    }

    func testEncodeSecondFailurePauses() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "enc", self.changeSetReply(pre: Precondition(status: "closed", assignee: nil)))
        }
        let (d, rec) = try paused(try await executor(runner).run(PlannedRound(stage: .encode, round: 0, major: true),
                                                                 inputs(config(), tape: try refineTape())))
        XCTAssertEqual(d.category, .invalidOutput)
        XCTAssertTrue(d.detail.contains("fd-1"), d.detail)
        XCTAssertEqual(runner.calls("encoder").count + runner.calls("correction").count, 2)
        XCTAssertEqual(rec.slots.first?.status, .failed)
    }

    func polishTape() throws -> Tape {
        var tape = try refineTape()
        let cs = ChangeSet(graphObservedAt: now, ops: [.editBead(id: "fd-1", set: FieldSet(title: "Renamed"), pre: existingPre, delivery: nil)])
        try seed(&tape, .encode, files: ["changeset.json": String(decoding: try cs.encoded(), as: UTF8.self), "plan.md": draftPlan])
        return tape
    }

    func testPolishKeepsExistingOpPreconditionsOrFails() async throws {
        // Keeps `pre` and adds one bead: accepted, one op changed.
        let good = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre, extra: [self.newBead]))
        }
        let (cp, files) = try checkpoint(try await executor(good).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                      inputs(config(), tape: try polishTape())))
        XCTAssertEqual(cp.record.changeCount, 1)
        XCTAssertEqual(try ChangeSet.decode(try XCTUnwrap(files["changeset.json"])).ops.count, 2)
        XCTAssertNotNil(files["plan.md"])
        let polisher = try XCTUnwrap(good.calls("polisher").first)
        XCTAssertTrue(polisher.prompt.contains(work.appendingPathComponent("changeset.json").path))
        XCTAssertEqual(try ChangeSet.decode(Data(contentsOf: work.appendingPathComponent("changeset.json"))).ops.count, 1,
                       "work/changeset.json is the CURRENT change set the polisher revises")

        // Rewrites the existing op's `pre`, twice: paused, never accepted.
        let bad = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: Precondition(status: "in_progress", assignee: "me")))
        }
        let (d, _) = try paused(try await executor(bad).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                           inputs(config(), tape: try polishTape())))
        XCTAssertEqual(d.category, .invalidOutput)
        XCTAssertTrue(d.detail.contains("fd-1"), d.detail)
        XCTAssertEqual(bad.calls("correction").count, 1)
    }

    // MARK: - Run layout

    func testEveryRunHasRunJSONWithPid() async throws {
        final class Seen: @unchecked Sendable { var preSpawn: [RunRecord?] = [] }
        let seen = Seen()
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "synthesizer" ? ok(call, "syn", self.review(1)) : self.editingIntegrator(call)
        }
        runner.onCall = { call in
            // Before `onSpawn`: run.json already exists, with no pid yet.
            let url = call.runDirectory!.appendingPathComponent("run.json")
            seen.preSpawn.append(try? IntakeJSON.decoder.decode(RunRecord.self, from: Data(contentsOf: url)))
        }
        let cfg = config(integrator: codexA)
        _ = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                          inputs(cfg, tape: try synthesisTape())))
        XCTAssertEqual(seen.preSpawn.count, 2)
        for pre in seen.preSpawn { XCTAssertNotNil(pre); XCTAssertNil(pre?.pid) }
        for (name, session) in [("synthesis-0-synthesizer", "syn"), ("synthesis-0-integrator", "int-1")] {
            let dir = store.runDirectory(name)
            let run = try IntakeJSON.decoder.decode(RunRecord.self, from: Data(contentsOf: dir.appendingPathComponent("run.json")))
            XCTAssertNotNil(run.pid, name)
            XCTAssertGreaterThan(run.pid ?? 0, 4000, name)
            XCTAssertEqual(run.sessionID, session)
            XCTAssertEqual(run.exitCode, 0)
            XCTAssertEqual(run.finished, now)
            XCTAssertFalse(try Data(contentsOf: dir.appendingPathComponent("stdout")).isEmpty, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stderr").path), name)
        }
        XCTAssertTrue(runner.calls.filter { $0.executable != "br" }.allSatisfy(\.processGroup))
    }

    /// A real `sleep 30` stands in for every harness child, through `SystemCommandRunner`'s own
    /// process-group path: ⏹ must reach it, not leave it running after the round is gone.
    func testCancellationKillsChildren() async throws {
        final class Sleeper: CommandRunner, @unchecked Sendable {
            let real = SystemCommandRunner()
            let lock = NSLock()
            var pid: Int32?, processGroup: Bool?
            func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                     processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
                if executable == "br" {
                    let out = arguments.first == "list" ? #"{"issues":[]}"# : #"{"components":[]}"#
                    return CommandResult(stdout: Data(out.utf8), stderr: "", exitCode: 0)
                }
                lock.withLock { self.processGroup = processGroup }
                return try await real.run(executable: "sleep", arguments: ["30"], cwd: cwd,
                                          environment: ["PATH": "/usr/bin:/bin"], processGroup: processGroup,
                                          onSpawn: { [self] p in lock.withLock { pid = p }; onSpawn?(p) })
            }
            var spawned: Int32? { lock.lock(); defer { lock.unlock() }; return pid }
        }
        let sleeper = Sleeper()
        let ex = executor(sleeper)
        let ins = inputs(config())
        let task = Task { try await ex.run(PlannedRound(stage: .draft, round: 0, major: true), ins) }
        var waited = 0
        while sleeper.spawned == nil, waited < 100 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        let pid = try XCTUnwrap(sleeper.spawned)
        XCTAssertEqual(sleeper.processGroup, true)
        XCTAssertEqual(kill(pid, 0), 0, "the child is running before ⏹")

        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        while kill(pid, 0) == 0, Date().timeIntervalSince(cancelledAt) < 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
    }
}
