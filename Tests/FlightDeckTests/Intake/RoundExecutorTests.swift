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
    // `bv` calls fall through to the default "polisher" role (their argv has no prompt for
    // `role` to match against), so exclude them here the same way `br` already is — otherwise
    // `calls("polisher").first` would return FD's own bv analytics call instead of the
    // polisher's actual harness turn, since the analytics run before it.
    func calls(_ role: String) -> [Call] { calls.filter { $0.executable != "br" && $0.executable != "bv" && $0.role == role } }

    var graphList = #"{"issues":[{"id":"fd-1","title":"Existing","status":"open","labels":[]}]}"#
    var graphEdges = #"{"components":[{"edges":[]}]}"#
    /// Controls `RoundExecutor.buildShadowAnalytics`'s three `bv` calls: `0` (default) answers
    /// every one with `bvStdout`; any other code simulates a `bv` failure, which the redirect
    /// requires to drop the analytics but still let the round run to completion.
    var bvExitCode: Int32 = 0
    var bvStdout = #"{"ok":true}"#
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
            // A polish round's `ShadowGraph.build` (Task 7b wiring) puts `--db <path>` first,
            // ahead of the subcommand — dispatch on `arguments[2]` rather than `arguments.first`
            // for those, and reuse the same `graphList`/`graphEdges` fixtures a test already set
            // for the live graph read: nothing in these tests needs the shadow to diverge from it.
            if arguments.first == "--db" {
                guard arguments.count >= 3 else { return CommandResult(stdout: Data(), stderr: "", exitCode: 127) }
                switch arguments[2] {
                case "list": return CommandResult(stdout: Data(graphList.utf8), stderr: "", exitCode: 0)
                case "graph": return CommandResult(stdout: Data(graphEdges.utf8), stderr: "", exitCode: 0)
                case "create":
                    let title = arguments[arguments.firstIndex(of: "--title")! + 1]
                    return CommandResult(stdout: Data(#"{"id":"shadow-\#(title)"}"#.utf8), stderr: "", exitCode: 0)
                default: return CommandResult(stdout: Data(), stderr: "", exitCode: 0)   // update, dep add
                }
            }
            let out = arguments.first == "list" ? graphList : graphEdges
            return CommandResult(stdout: Data(out.utf8), stderr: "", exitCode: 0)
        }
        if executable == "bv" {
            // `RoundExecutor.buildShadowAnalytics` — FD's own `bv --robot-insights/-plan/-priority`
            // runs against the shadow, never the agent's. Scripted the same way `br` is above:
            // the tests never need these to diverge from `bvStdout`/`bvExitCode`.
            return CommandResult(stdout: Data(bvStdout.utf8), stderr: bvExitCode == 0 ? "" : "bv: failed", exitCode: bvExitCode)
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

/// `claude -p --output-format stream-json --verbose`'s shape: an init line, then (after the
/// turn's own events) the final `result` carrying the structured output.
func claudeOK(_ session: String, _ json: String) -> CommandResult {
    let structured = try! JSONSerialization.jsonObject(with: Data(json.utf8))
    let initLine = try! JSONSerialization.data(withJSONObject: ["type": "system", "subtype": "init", "session_id": session])
    let result = try! JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false,
                                                              "session_id": session, "structured_output": structured])
    return CommandResult(stdout: Data((String(decoding: initLine, as: UTF8.self) + "\n" + String(decoding: result, as: UTF8.self) + "\n").utf8),
                         stderr: "", exitCode: 0)
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

    /// Checks the `--allowedTools`/`--disallowedTools` VALUES only, not the whole argv — the
    /// prompt itself is one of `arguments` too, and the polish-family prompt legitimately says
    /// the word "bv" in prose (pointing at the analytics files); only the tool-allow flags are
    /// the thing that must never mention it.
    func hasBvAllow(_ args: [String]) -> Bool {
        for flag in ["--allowedTools", "--disallowedTools"] {
            if let i = args.firstIndex(of: flag), args[i + 1].contains("bv") { return true }
        }
        return false
    }

    /// A minimal real `.beads` directory under `project` — `ShadowGraph.build`'s copy step is
    /// real `FileManager`, not the fake runner, so a shadow-success test needs something on
    /// disk to copy from (mirrors `ShadowGraphTests.makeProject`). Left uncalled, `project` has
    /// no `.beads` at all, which is exactly what exercises the build-failure path.
    func makeProjectBeads() throws {
        let beads = project.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
        try Data("placeholder\n".utf8).write(to: beads.appendingPathComponent("marker.txt"))
    }

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

    /// An empty home by default, so the operator's own `~/.claude/settings.json` never leaks in.
    var home: URL { root.appendingPathComponent("home") }
    func executor(_ runner: CommandRunner) -> RoundExecutor {
        RoundExecutor(runner: runner, graphReader: GraphReader(runner: runner, environment: [:]), userHome: home)
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

    /// `--restricted` drops the user settings' `env`; the executor puts it back for
    /// claude children only, under the explicit environment, and before the unsets.
    func testClaudeChildrenGetTheUserSettingsEnvUnderneathTheProcessEnv() async throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"http://localhost:8787","PATH":"/settings/bin","CLAUDECODE":"1"}}"#.utf8)
            .write(to: settings)
        let runner = ScriptedHarnessRunner { call in ok(call, "s", json(DraftOutput(plan: "# P"))) }
        let cfg = config(drafters: [Slot(codexA), Slot(claudeB)])
        _ = try checkpoint(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true), inputs(cfg)))
        let claude = try XCTUnwrap(runner.calls("drafter").first { $0.executable == "claude" })
        XCTAssertEqual(claude.environment["ANTHROPIC_BASE_URL"], "http://localhost:8787")
        XCTAssertEqual(claude.environment["PATH"], "/usr/bin:/bin", "the explicit environment wins")
        XCTAssertNil(claude.environment["CLAUDECODE"], "the unsets run after the merge")
        let codex = try XCTUnwrap(runner.calls("drafter").first { $0.executable == "codex" })
        XCTAssertNil(codex.environment["ANTHROPIC_BASE_URL"])
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
        // Drafter 0 (and its fallback) fail on auth, drafter 1 (and its fallback) on a rate
        // limit: the pause carries drafter 0's diagnosis, not whichever finished last.
        let runner = ScriptedHarnessRunner { call in
            call.prompt.contains("Your lens: global coherence") ? failed("Error: 401 Unauthorized")
                                                                 : failed("Error: 429 rate limit exceeded")
        }
        let cfg = config(drafters: [Slot(codexA, persona: .arbiter, fallback: claudeB),
                                    Slot(claudeB, persona: .realist, fallback: codexA)])
        let (d, rec) = try paused(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true), inputs(cfg)))
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(rec.slots.map(\.status), [.failed, .failed])
        XCTAssertEqual(rec.slots.map { $0.diagnosis?.category }, [.authExpired, .rateLimited])
        XCTAssertEqual(runner.calls("drafter").count, 4, "each drafter plus its fallback, exactly once")
    }

    /// A drafter's own words are not a diagnosis: this one wrote about "401 authentication"
    /// and then died, which is a crash to retry — not a login to renew.
    func testDrafterExitingNonzeroIsNotDiagnosedFromItsOwnText() async throws {
        let runner = ScriptedHarnessRunner { call in
            let out = codexOK("d", json(DraftOutput(plan: "Handle 401 authentication failures"))).stdout
            return CommandResult(stdout: out, stderr: "", exitCode: 1)
        }
        let (d, rec) = try paused(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true),
                                                                 inputs(config())))
        XCTAssertEqual(d.category, .harnessError)
        XCTAssertEqual(rec.slots.first?.diagnosis?.category, .harnessError)
    }

    /// Annotations are consumed by whichever round runs next — here a polish round, long after
    /// refinement ended — and reach its prompt in the shared steering words.
    func testPolishConsumesAnnotations() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre, extra: [self.newBead]))
        }
        var tape = try polishTape()
        tape.pendingNotes = [PlanNote(note: "split the auth bead")]
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                    inputs(config(), tape: tape)))
        XCTAssertEqual(cp.record.annotations.map(\.note), ["split the auth bead"])
        let polisher = try XCTUnwrap(runner.calls("polisher").first)
        XCTAssertTrue(polisher.prompt.contains("The human steering this plan says:\n- split the auth bead"), polisher.prompt)
    }

    func testDraftConsumesAnnotations() async throws {
        let runner = ScriptedHarnessRunner { call in ok(call, "d", json(DraftOutput(plan: "# P"))) }
        var tape = Tape()
        tape.pendingNotes = [PlanNote(note: "web only")]
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true),
                                                                    inputs(config(), tape: tape)))
        XCTAssertEqual(cp.record.annotations.map(\.note), ["web only"])
        XCTAssertTrue(try XCTUnwrap(runner.calls("drafter").first).prompt.contains("- web only"))
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

    /// `work/changes.json` is overwritten by the next round, so the checkpoint keeps its own
    /// copy — the proposals are what "is this round repeating the last one" is judged on — and
    /// the integrator's per-change verdicts beside it.
    func testReviewRoundKeepsItsProposedChangesAndVerdictsInTheCheckpoint() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            guard call.role == "synthesizer" else {
                _ = self.editingIntegrator(call)
                // The counts say otherwise; the list is what the totals come from.
                return ok(call, "int", json(IntegrateOutput(agree: 0, somewhat: 0, disagree: 2, notes: "applied",
                                                            verdicts: [ChangeVerdict(index: 1, verdict: .somewhat),
                                                                       ChangeVerdict(index: 0, verdict: .agree)])))
            }
            return ok(call, "syn", self.review(2))
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                        inputs(config(), tape: try synthesisTape())))
        let changes = try IntakeJSON.decoder.decode([ProposedChange].self, from: try XCTUnwrap(files["changes.json"]))
        XCTAssertEqual(changes.map(\.rationale), ["r0", "r1"])
        let verdicts = try IntakeJSON.decoder.decode([ChangeVerdict].self, from: try XCTUnwrap(files["verdicts.json"]))
        XCTAssertEqual(verdicts, [ChangeVerdict(index: 0, verdict: .agree), ChangeVerdict(index: 1, verdict: .somewhat)])
        XCTAssertEqual(cp.record.tally, VerdictTally(agree: 1, somewhat: 1, disagree: 0))
        XCTAssertFalse(cp.record.note?.contains("tallied") ?? false, cp.record.note ?? "nil")
    }

    /// An integrator that answers in the old shape (no verdicts) still lands its round: the
    /// proposals are kept, the counts are the tally, and there is no verdicts file to mislead.
    func testIntegratorWithoutVerdictsKeepsChangesButNoVerdictsFile() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "synthesizer" ? ok(call, "syn", self.review(2)) : self.editingIntegrator(call)
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                        inputs(config(), tape: try synthesisTape())))
        XCTAssertNotNil(files["changes.json"])
        XCTAssertNil(files["verdicts.json"])
        XCTAssertEqual(cp.record.tally, VerdictTally(agree: 1, somewhat: 1, disagree: 0))
    }

    /// A reviewer that found nothing is the convergence signal; its empty list is kept too, so
    /// "this round proposed nothing" is on disk rather than inferred from a missing file.
    func testReviewWithNoChangesKeepsAnEmptyChangesFile() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "synthesizer" ? ok(call, "syn", self.review(0)) : failed("the integrator must not run")
        }
        let (_, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                       inputs(config(), tape: try synthesisTape())))
        XCTAssertEqual(try IntakeJSON.decoder.decode([ProposedChange].self, from: try XCTUnwrap(files["changes.json"])), [])
        XCTAssertNil(files["verdicts.json"])
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

    func testReviewWithNoChangesSkipsTheIntegrator() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "synthesizer" ? ok(call, "syn", self.review(0)) : failed("the integrator must not run")
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                        inputs(config(), tape: try synthesisTape())))
        XCTAssertTrue(runner.calls("integrator").isEmpty)
        XCTAssertEqual(cp.record.changeCount, 0)
        XCTAssertEqual(cp.record.slots.map(\.role), ["synthesizer"])
        XCTAssertEqual(text(files["plan.md"]), draftPlan)
    }

    func testTallyThatDoesNotAddUpIsNotedNotPaused() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            guard call.role == "synthesizer" else {
                // Three proposed, but only two verdicts reported.
                _ = self.editingIntegrator(call)
                return ok(call, "int", json(IntegrateOutput(agree: 1, somewhat: 1, disagree: 0, notes: "applied")))
            }
            return ok(call, "syn", self.review(3))
        }
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                    inputs(config(), tape: try synthesisTape())))
        XCTAssertEqual(cp.record.changeCount, 3)
        XCTAssertTrue(cp.record.note?.contains("tallied 2 verdicts for 3 proposed changes") ?? false, cp.record.note ?? "nil")
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
        tape.pendingNotes = [PlanNote(note: "focus on auth")]
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                    inputs(config(), tape: tape)))
        XCTAssertEqual(cp.record.annotations.map(\.note), ["focus on auth"])
        XCTAssertTrue(try XCTUnwrap(runner.calls("reviewer").first).prompt.contains("focus on auth"))
    }

    // MARK: - Cross-check refine (coverage spec §4)

    /// Codex reviews as the primary, Claude as the cross-reviewer, Claude integrates. Both
    /// reviewers' prompts say "refinement round", so they are told apart by harness.
    func crossConfig() -> RoundConfig {
        var c = config()
        c.reviewer = Slot(codexA)
        c.crossReviewer = Slot(claudeB)
        c.crossCheck = .firstAndLast
        return c
    }
    let crossRound = PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true)

    func reviewTagged(_ tag: String, _ n: Int) -> String {
        json(ReviewOutput(changes: (0..<n).map { ProposedChange(section: "## Scope", rationale: "\(tag)\($0)", edit: "add \(tag)\($0)") },
                          summary: "\(tag) found \(n)"))
    }

    func clusteringIntegrator(_ call: ScriptedHarnessRunner.Call, clusters: [[Int]]?) -> CommandResult {
        let plan = call.cwd.appendingPathComponent("plan.md")
        let before = (try? String(contentsOf: plan, encoding: .utf8)) ?? ""
        try! (before + "\n## Added\nnew line\n").write(to: plan, atomically: true, encoding: .utf8)
        let n = (try? IntakeJSON.decoder.decode([ProposedChange].self,
                                                from: Data(contentsOf: call.cwd.appendingPathComponent("changes.json"))))?.count ?? 0
        let verdicts = (0..<n).map { ChangeVerdict(index: $0, verdict: .agree) }
        return ok(call, "int", json(IntegrateOutput(agree: n, somewhat: 0, disagree: 0, notes: "applied",
                                                    verdicts: verdicts, clusters: clusters)))
    }

    func testCrossCheckRunsBothReviewersAndStoresTheRecord() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return call.executable == "codex" ? ok(call, "p", self.reviewTagged("a", 3)) : ok(call, "c", self.reviewTagged("b", 2))
            default: return self.clusteringIntegrator(call, clusters: [[0, 1], [9, 9]])
            }
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        XCTAssertEqual(runner.calls("reviewer").count, 2)
        XCTAssertEqual(Set(runner.calls("reviewer").map(\.executable)), ["codex", "claude"])
        XCTAssertEqual(cp.record.slots.map(\.role), ["reviewer", "crossReviewer", "integrator"])
        XCTAssertEqual(cp.record.changeCount, 5)
        let record = try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: XCTUnwrap(files[CrossCheckRecord.fileName]))
        XCTAssertEqual(record.families, [.codex, .claude])
        XCTAssertEqual(record.proposers.count, 5)
        XCTAssertEqual(record.clusters, [[0, 1]], "cleaned: the out-of-range pair is dropped")
        XCTAssertEqual(record.blindOrderSeed, cp.id)
        let stored = try IntakeJSON.decoder.decode([ProposedChange].self, from: XCTUnwrap(files["changes.json"]))
        XCTAssertEqual(stored.count, 5)
        for (change, p) in zip(stored, record.proposers) { XCTAssertTrue(change.rationale.hasPrefix(p == 0 ? "a" : "b")) }
        XCTAssertNotNil(files["verdicts.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory("refine-1-crossReviewer").path))
    }

    /// The integrator is handed the blind list and the clustered schema; no proposer shows.
    func testCrossCheckIntegratorIsBlindAndClustered() async throws {
        let seen = LockedBox<(changes: String, schema: String)>()
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return call.executable == "codex" ? ok(call, "p", self.reviewTagged("a", 2)) : ok(call, "c", self.reviewTagged("b", 2))
            default:
                let changes = try! String(contentsOf: call.cwd.appendingPathComponent("changes.json"), encoding: .utf8)
                let schemaDir = self.store.runDirectory("refine-1-integrator")
                let schema = (try? String(contentsOf: schemaDir.appendingPathComponent("schema.json"), encoding: .utf8)) ?? ""
                seen.set((changes, schema))
                return self.clusteringIntegrator(call, clusters: nil)
            }
        }
        _ = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        let got = try XCTUnwrap(seen.value)
        XCTAssertFalse(got.changes.contains("proposer"))
        XCTAssertFalse(got.changes.contains("codex") || got.changes.contains("claude"))
        XCTAssertTrue(got.schema.contains("clusters"))
        XCTAssertTrue(try XCTUnwrap(runner.calls("integrator").first).prompt.contains("same underlying issue"))
    }

    /// Review Focus 2: an integrator that answers without clusters still lands the round.
    func testCrossCheckWithoutClustersStillLands() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return ok(call, "r", self.reviewTagged(call.executable == "codex" ? "a" : "b", 1))
            default: return self.editingIntegrator(call)   // plain IntegrateOutput, no clusters key
            }
        }
        let (_, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        XCTAssertNil(try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: XCTUnwrap(files[CrossCheckRecord.fileName])).clusters)
    }

    func testCrossReviewerFailureDegradesToASingleReview() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return call.executable == "codex" ? ok(call, "p", self.review(2)) : failed("rate limit exceeded")
            default: return self.editingIntegrator(call)
            }
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        XCTAssertNil(files[CrossCheckRecord.fileName])
        XCTAssertEqual(cp.record.slots.first { $0.role == "crossReviewer" }?.status, .failed)
        XCTAssertEqual(cp.record.changeCount, 2)
        XCTAssertFalse(try XCTUnwrap(runner.calls("integrator").first).prompt.contains("same underlying issue"))
    }

    func testPrimaryFallbackToTheOtherFamilyIsRecordedAsSameFamily() async throws {
        var cfg = crossConfig()
        cfg.reviewer = Slot(codexA, fallback: claudeB)
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return call.executable == "codex" ? failed("boom") : ok(call, "c", self.review(1))
            default: return self.clusteringIntegrator(call, clusters: nil)
            }
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(cfg, tape: try refineTape())))
        XCTAssertEqual(cp.record.slots.first { $0.role == "reviewer" }?.status, .substituted)
        XCTAssertEqual(try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: XCTUnwrap(files[CrossCheckRecord.fileName])).families,
                       [.claude, .claude])
    }

    /// Review Focus 3: both reviewers found nothing, so there is no integrator, but the record is kept.
    func testCrossCheckWhereNobodyFindsAnything() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "r", self.review(0)) : failed("the integrator must not run")
        }
        let (_, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        XCTAssertTrue(runner.calls("integrator").isEmpty)
        XCTAssertEqual(try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: XCTUnwrap(files[CrossCheckRecord.fileName])).proposers, [])
    }

    func testANonCrossCheckRoundIsUnchanged() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "r", self.review(1)) : self.editingIntegrator(call)
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 2, major: false),
                                                                        inputs(crossConfig(), tape: try refineTape())))
        XCTAssertEqual(runner.calls("reviewer").count, 1)
        XCTAssertEqual(cp.record.slots.map(\.role), ["reviewer", "integrator"])
        XCTAssertNil(files[CrossCheckRecord.fileName])
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

    // MARK: - Seat results

    /// Each seat leaves `runs/<run>/result.json` the moment its own output parses, so its row
    /// shows what it did while the rest of the round is still running — not only once the whole
    /// round's checkpoint lands.
    func testDraftersWriteTheirResultAsTheyFinish() async throws {
        let runner = ScriptedHarnessRunner { call in
            call.model == "A" ? failed("Error: 401 Unauthorized") : ok(call, "s", json(DraftOutput(plan: "# P\n\n- One\n- Two\n")))
        }
        let cfg = config(drafters: [Slot(codexA, fallback: claudeB), Slot(claudeB)])
        _ = try checkpoint(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true), inputs(cfg)))
        XCTAssertNil(store.seatResult(run: "draft-0-drafter-0"), "the attempt that failed produced nothing")
        XCTAssertEqual(store.seatResult(run: "draft-0-drafter-0-fallback"), SeatResult(kind: .draft, linesAdded: 4))
        XCTAssertEqual(store.seatResult(run: "draft-0-drafter-1"), SeatResult(kind: .draft, linesAdded: 4))
    }

    func testReviewerAndIntegratorWriteTheirResults() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "synthesizer":
                return ok(call, "syn", json(ReviewOutput(changes: [
                    ProposedChange(section: "## 2. Scope", rationale: "r", edit: "e"),
                    ProposedChange(section: "## 4. Dispatch", rationale: "r", edit: "e"),
                    ProposedChange(section: "## 2. Scope", rationale: "r", edit: "e"),
                ], summary: "three")))
            default: return self.editingIntegrator(call)
            }
        }
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                    inputs(config(), tape: try synthesisTape())))
        XCTAssertEqual(store.seatResult(run: "synthesis-0-synthesizer"),
                       SeatResult(kind: .reviewer, changeCount: 3, sections: ["## 2. Scope", "## 4. Dispatch"]),
                       "each section once, in the order proposed")
        XCTAssertEqual(store.seatResult(run: "synthesis-0-integrator"),
                       SeatResult(kind: .integrator, sections: cp.record.sectionsChanged, agree: 1, somewhat: 1, disagree: 0,
                                  linesAdded: 3, linesRemoved: 0))
    }

    /// A change-set seat's result sits on the run whose change set was accepted — the
    /// correction when there was one — and counts what the checkpoint counts.
    func testChangeSetSeatsWriteTheirOpCount() async throws {
        let encoder = ScriptedHarnessRunner { [unowned self] call in
            call.role == "encoder" ? ok(call, "enc-1", self.changeSetReply(pre: Precondition(status: "closed", assignee: nil)))
                : ok(call, "enc-1", self.changeSetReply(pre: self.existingPre, extra: [self.newBead]))
        }
        _ = try checkpoint(try await executor(encoder).run(PlannedRound(stage: .encode, round: 0, major: true),
                                                           inputs(config(), tape: try refineTape())))
        XCTAssertNil(store.seatResult(run: "encode-0-encoder"), "its change set failed validation")
        XCTAssertEqual(store.seatResult(run: "encode-0-encoder-correction"), SeatResult(kind: .changeSet, ops: 2))

        let polisher = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre, extra: [self.newBead]))
        }
        let (cp, _) = try checkpoint(try await executor(polisher).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                      inputs(config(), tape: try polishTape())))
        XCTAssertEqual(store.seatResult(run: "polish-1-polisher"), SeatResult(kind: .changeSet, ops: cp.record.changeCount))
    }

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
        XCTAssertEqual(correction.prompt, RoundPrompts.changeSetCorrection(
            errors: [.preconditionMismatch("fd-1")], observedAt: now), "the change-set correction, not triage's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("graph.json").path))
        let saved = try IntakeJSON.decoder.decode(GraphSnapshot.self, from: try XCTUnwrap(files["graph.json"]))
        XCTAssertEqual(saved.beads["fd-1"]?.status, "open", "the checkpoint keeps the graph encode validated against")
        XCTAssertTrue(try XCTUnwrap(runner.calls("encoder").first).prompt.contains(work.appendingPathComponent("graph.json").path))
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

    let encodeObservedAt = Date(timeIntervalSince1970: 1_789_000_000)
    func polishTape() throws -> Tape {
        var tape = try refineTape()
        let cs = ChangeSet(graphObservedAt: encodeObservedAt,
                           ops: [.editBead(id: "fd-1", set: FieldSet(title: "Renamed"), pre: existingPre, delivery: nil)])
        let graph = GraphSnapshot(beads: ["fd-1": BeadSnapshot(id: "fd-1", title: "Existing", status: "open")])
        try seed(&tape, .encode, files: ["changeset.json": String(decoding: try cs.encoded(), as: UTF8.self), "plan.md": draftPlan,
                                         "graph.json": json(graph)])
        return tape
    }

    /// A tape whose encode predates the saved snapshot must still move: pausing would write no
    /// checkpoint, so the planner would hand back this same polish round and ⏯ would loop on the
    /// same pause forever. Read the graph once, and save it for later rounds to carry forward.
    func testPolishWithNoEncodeGraphReadsTheGraphFreshOnceAndSavesIt() async throws {
        var tape = try refineTape()
        let cs = ChangeSet(graphObservedAt: encodeObservedAt,
                           ops: [.editBead(id: "fd-1", set: FieldSet(title: "Renamed"), pre: existingPre, delivery: nil)])
        try seed(&tape, .encode, files: ["changeset.json": String(decoding: try cs.encoded(), as: UTF8.self), "plan.md": draftPlan])
        let runner = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre, extra: [self.newBead]))
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                        inputs(config(), tape: tape)))
        XCTAssertEqual(runner.calls.filter { $0.executable == "br" && $0.arguments.first == "list" }.count, 1)
        let saved = try IntakeJSON.decoder.decode(GraphSnapshot.self, from: try XCTUnwrap(files["graph.json"]))
        XCTAssertEqual(saved.beads["fd-1"]?.status, "open")
        XCTAssertTrue(cp.record.note?.contains("no encode graph snapshot; read the graph fresh") ?? false, cp.record.note ?? "nil")
        XCTAssertEqual(try ChangeSet.decode(try XCTUnwrap(files["changeset.json"])).graphObservedAt, now,
                       "stamped with the read it was actually validated against")
    }

    /// Drift after encode is release's job: polish validates against the graph encode saw, so a
    /// bead that has since moved must not pause a polisher that kept its `pre` as told.
    func testBeadChangedAfterEncodeDoesNotPausePolish() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre, extra: [self.newBead]))
        }
        runner.graphList = #"{"issues":[{"id":"fd-1","title":"Existing","status":"in_progress","assignee":"someone","labels":[]}]}"#
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                        inputs(config(), tape: try polishTape())))
        XCTAssertEqual(cp.record.slots.map(\.status), [.ok])
        XCTAssertTrue(runner.calls("correction").isEmpty)
        XCTAssertFalse(runner.calls.contains { $0.executable == "br" }, "polish never re-reads the live graph")
        XCTAssertEqual(try ChangeSet.decode(try XCTUnwrap(files["changeset.json"])).graphObservedAt, encodeObservedAt)
        let carried = try IntakeJSON.decoder.decode(GraphSnapshot.self, from: try XCTUnwrap(files["graph.json"]))
        XCTAssertEqual(carried.beads["fd-1"]?.status, "open")
        let polisher = try XCTUnwrap(runner.calls("polisher").first)
        XCTAssertTrue(polisher.prompt.contains(work.appendingPathComponent("graph.json").path))
    }

    /// A polish round's size is its ops changed; the dependency-edge share of that is kept on
    /// its own, since "dependencies stabilizing" is the signal polish convergence leans on most.
    func testPolishRecordsEdgeChurnSeparatelyFromOpsChanged() async throws {
        let edge = ChangeOp.addEdge(from: .new("t1"), to: .existing("fd-1"), kind: .blocks)
        let runner = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre, extra: [self.newBead, edge]))
        }
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                    inputs(config(), tape: try polishTape())))
        XCTAssertEqual(cp.record.changeCount, 2, "the new bead and the new edge")
        XCTAssertEqual(cp.record.edgesChanged, 1)
    }

    /// A record written before `edgesChanged` existed decodes with none, and one that has it
    /// round-trips.
    func testRoundRecordEdgesChangedIsOptionalOnDisk() throws {
        let old = Data(#"{"slots":[],"changeCount":3,"linesAdded":0,"linesRemoved":0,"sectionsChanged":[],"annotations":[]}"#.utf8)
        XCTAssertNil(try IntakeJSON.decoder.decode(RoundRecord.self, from: old).edgesChanged)
        let rec = RoundRecord(changeCount: 3, edgesChanged: 2)
        XCTAssertEqual(try IntakeJSON.decoder.decode(RoundRecord.self, from: IntakeJSON.encoder.encode(rec)), rec)
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

    // MARK: - Shadow graph + bv analytics (Task 7b wiring)

    /// A shadow builds successfully (`project/.beads` exists): FD itself runs the three `bv`
    /// robot reports against it — never the agent — writes each to `work/bv-*.json`, and the
    /// prompt names those files. No claude argv anywhere carries a `bv` allow, scoped or not.
    func testPolishBuildsShadowRunsBvItselfAndPointsThePromptAtTheFiles() async throws {
        try makeProjectBeads()
        let runner = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre))
        }
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                     inputs(config(), tape: try polishTape())))
        XCTAssertEqual(cp.record.slots.map(\.status), [.ok])
        XCTAssertFalse(cp.record.note?.contains("unavailable") ?? false, cp.record.note ?? "nil")

        // `shadow.build`'s return value IS the `.beads` directory — that's the path `bv --db`
        // takes (it accepts either form); `br --db` always takes the `beads.db` FILE inside it.
        let shadowBeads = work.appendingPathComponent("shadow/.beads", isDirectory: true)
        let dbFilePath = shadowBeads.appendingPathComponent("beads.db").path
        let insightsPath = work.appendingPathComponent("bv-insights.json").path
        let planPath = work.appendingPathComponent("bv-plan.json").path
        let priorityPath = work.appendingPathComponent("bv-priority.json").path

        let polisher = try XCTUnwrap(runner.calls("polisher").first)
        XCTAssertTrue(polisher.prompt.contains(insightsPath), polisher.prompt)
        XCTAssertTrue(polisher.prompt.contains(planPath), polisher.prompt)
        XCTAssertTrue(polisher.prompt.contains(priorityPath), polisher.prompt)
        XCTAssertFalse(hasBvAllow(polisher.arguments),
                       "claude polisher argv must never carry a bv allow: \(polisher.arguments)")
        for call in runner.calls where call.executable == "claude" {
            XCTAssertFalse(hasBvAllow(call.arguments), "\(call.role): \(call.arguments)")
        }

        let bvCalls = runner.calls.filter { $0.executable == "bv" }
        XCTAssertEqual(bvCalls.map { $0.arguments[2] }.sorted(), ["--robot-insights", "--robot-plan", "--robot-priority"])
        for call in bvCalls {
            XCTAssertEqual(call.arguments[0], "--db")
            XCTAssertEqual(call.arguments[1], shadowBeads.path)
            XCTAssertNotEqual(call.cwd.standardizedFileURL.path, project.standardizedFileURL.path,
                              "bv ran with cwd = project: \(call.arguments)")
        }
        for path in [insightsPath, planPath, priorityPath] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        }

        let shadowCalls = runner.calls.filter { $0.executable == "br" && $0.arguments.first == "--db" }
        XCTAssertFalse(shadowCalls.isEmpty)
        for call in shadowCalls {
            XCTAssertEqual(call.arguments[1], dbFilePath)
            XCTAssertNotEqual(call.cwd.standardizedFileURL.path, project.standardizedFileURL.path,
                              "argv \(call.arguments) ran with cwd = project")
        }
    }

    /// No `.beads` under `project` at all: `ShadowGraph.build` fails before issuing any `br`
    /// or `bv` call, but the round still runs to completion (the shadow is an aid, not a gate)
    /// and the failure is folded into the checkpoint's note rather than pausing the round.
    func testShadowBuildFailureStillRunsPolishAndRecordsNote() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre))
        }
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                     inputs(config(), tape: try polishTape())))
        XCTAssertEqual(cp.record.slots.map(\.status), [.ok])
        XCTAssertTrue(cp.record.note?.contains("shadow graph unavailable") ?? false, cp.record.note ?? "nil")
        let polisher = try XCTUnwrap(runner.calls("polisher").first)
        XCTAssertFalse(polisher.prompt.contains("bv-insights.json"), "no analytics guidance when the shadow build fails")
        XCTAssertFalse(runner.calls.contains { $0.executable == "br" }, "copyBeads fails before any br call runs")
        XCTAssertFalse(runner.calls.contains { $0.executable == "bv" }, "no bv run without a shadow to run it against")
    }

    /// The shadow builds, but `bv` itself fails (e.g. not on PATH, or a genuine error): the
    /// round still runs to completion, the failure note replaces the analytics rather than
    /// pausing anything, and the prompt carries no analytics guidance.
    func testBvFailureStillRunsPolishAndRecordsNote() async throws {
        try makeProjectBeads()
        let runner = ScriptedHarnessRunner { [unowned self] call in
            ok(call, "pol", self.changeSetReply(pre: self.existingPre))
        }
        runner.bvExitCode = 1
        runner.bvStdout = "database not found"
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .polish, round: 1, major: true),
                                                                     inputs(config(), tape: try polishTape())))
        XCTAssertEqual(cp.record.slots.map(\.status), [.ok])
        XCTAssertTrue(cp.record.note?.contains("bv analytics unavailable") ?? false, cp.record.note ?? "nil")
        let polisher = try XCTUnwrap(runner.calls("polisher").first)
        XCTAssertFalse(polisher.prompt.contains("bv-insights.json"), "no analytics guidance when bv itself fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("bv-insights.json").path))
    }

    /// No claude seat, anywhere in the round system — polish family or not — ever carries a
    /// `bv` allow. A scoped `Bash(bv --db <shadow> *)` would still match `bv`'s write flags on
    /// the same invocation, so FD runs `bv` itself instead (see the tests above) and no seat is
    /// ever granted it at all.
    func testNoClaudeArgvAnywhereEverAllowsBv() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "rev", self.review(1)) : self.editingIntegrator(call)
        }
        _ = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                           inputs(config(), tape: try refineTape())))
        let claudeCalls = runner.calls.filter { $0.executable == "claude" }
        XCTAssertFalse(claudeCalls.isEmpty)
        for call in claudeCalls {
            XCTAssertFalse(hasBvAllow(call.arguments), "\(call.role): \(call.arguments)")
        }
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

    /// `runs/<run>/stdout` grows while the child runs and `activity.json` exists from the start,
    /// so the app can show a seat mid-turn; at exit the file is the whole stream exactly once
    /// and the activity is the stream's fold, finished.
    func testSeatStreamsStdoutAndActivityWhileItRuns() async throws {
        final class Streaming: CommandRunner, @unchecked Sendable {
            let inner: ScriptedHarnessRunner
            var midStream: (stdout: String, activity: SeatActivity?)?
            init(_ inner: ScriptedHarnessRunner) { self.inner = inner }
            func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                     processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
                try await inner.run(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                                    processGroup: processGroup, onSpawn: onSpawn)
            }
            func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                     processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?,
                     onStdout: (@Sendable (Data) -> Void)?) async throws -> CommandResult {
                let result = try await run(executable: executable, arguments: arguments, cwd: cwd,
                                           environment: environment, processGroup: processGroup, onSpawn: onSpawn)
                guard executable == "codex", let i = arguments.firstIndex(of: "--output-schema") else {
                    if !result.stdout.isEmpty { onStdout?(result.stdout) }
                    return result
                }
                let dir = URL(fileURLWithPath: arguments[i + 1]).deletingLastPathComponent()
                let command = Data((#"{"type":"item.started","item":{"type":"command_execution","command":"/bin/zsh -lc \"sed -n '1,9p' README.md\""}}"# + "\n").utf8)
                onStdout?(command)
                midStream = (String(decoding: (try? Data(contentsOf: dir.appendingPathComponent("stdout"))) ?? Data(), as: UTF8.self),
                             try? IntakeJSON.decoder.decode(SeatActivity.self, from: Data(contentsOf: dir.appendingPathComponent("activity.json"))))
                onStdout?(result.stdout)
                return CommandResult(stdout: command + result.stdout, stderr: result.stderr, exitCode: result.exitCode)
            }
        }
        let runner = Streaming(ScriptedHarnessRunner { call in ok(call, "s", json(DraftOutput(plan: "# P"))) })
        _ = try checkpoint(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true), inputs(config())))

        let mid = try XCTUnwrap(runner.midStream)
        XCTAssertTrue(mid.stdout.contains("sed -n"), "the first event is on disk before the child exits")
        XCTAssertEqual(mid.activity?.finished, false, "activity.json is written at start")
        let dir = store.runDirectory("draft-0-drafter-0")
        let stdout = try Data(contentsOf: dir.appendingPathComponent("stdout"))
        XCTAssertEqual(stdout.split(separator: 0x0A).count, 3, "command + thread.started + agent_message, each once")
        let activity = try IntakeJSON.decoder.decode(SeatActivity.self, from: Data(contentsOf: dir.appendingPathComponent("activity.json")))
        XCTAssertTrue(activity.finished)
        XCTAssertNil(activity.error)
        XCTAssertEqual(activity.action, ActivityAction(verb: "Reading", object: "README.md"))
        XCTAssertEqual(activity.footprint, [".": 1])
    }

    /// A stream that fails to write must not leave run.json looking like a child still alive.
    /// (stdout is written live from before the spawn; stderr is still written at exit.)
    func testRunJSONIsFinishedEvenWhenAStreamWriteFails() async throws {
        let runner = ScriptedHarnessRunner { call in ok(call, "s", json(DraftOutput(plan: "# P"))) }
        runner.onCall = { call in
            // A directory where the stderr file goes: the write after exit fails.
            try? FileManager.default.createDirectory(at: call.runDirectory!.appendingPathComponent("stderr"),
                                                     withIntermediateDirectories: true)
        }
        let (d, _) = try paused(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true), inputs(config())))
        XCTAssertEqual(d.category, .harnessError)
        let run = try IntakeJSON.decoder.decode(RunRecord.self, from: Data(contentsOf:
            store.runDirectory("draft-0-drafter-0").appendingPathComponent("run.json")))
        XCTAssertNotNil(run.pid)
        XCTAssertEqual(run.finished, now)
        XCTAssertEqual(run.exitCode, 0)
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

// MARK: - Human edits (plan.user.md)

extension RoundExecutorTests {
    var editedPlan: String { "# Plan\n\n## Scope\nOne, but only on macOS\n" }

    func writeUserEdits(_ markdown: String, checkpoint: Int) throws {
        try Data(markdown.utf8).write(to: store.userEditsURL(checkpoint: checkpoint))
    }

    /// The head's edited layer is the plan the reviewer is pointed at and the integrator
    /// starts from, and both seats are told the edits are authoritative, with the diff.
    func testRefineReadsTheHeadsEffectivePlanAndCarriesTheEdits() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "rev", self.review(1)) : self.editingIntegrator(call)
        }
        let tape = try refineTape()
        try writeUserEdits(editedPlan, checkpoint: 2)
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                        inputs(config(), tape: tape)))
        XCTAssertEqual(text(files["plan.md"]), editedPlan + "\n## Added\nnew line\n", "built on the edited plan")
        let reviewer = try XCTUnwrap(runner.calls("reviewer").first)
        XCTAssertTrue(reviewer.prompt.contains(store.userEditsURL(checkpoint: 2).path), reviewer.prompt)
        for p in [reviewer.prompt, try XCTUnwrap(runner.calls("integrator").first).prompt] {
            XCTAssertTrue(p.contains("These edits are authoritative: keep them unless a note explicitly asks otherwise."), p)
            XCTAssertTrue(p.contains("-One\n+One, but only on macOS"), p)
        }
        XCTAssertFalse(cp.record.note?.contains("edited lines") ?? false, "the integrator kept the edit")
        XCTAssertEqual(try String(contentsOf: store.checkpointDirectory(2).appendingPathComponent("plan.md"), encoding: .utf8),
                       draftPlan, "the generated layer is never modified")
    }

    /// An integrator that rewrites the human's line lands the round — warn, don't pause.
    func testRoundThatChangesEditedLinesWarnsInItsRecord() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            guard call.role == "integrator" else { return ok(call, "rev", self.review(1)) }
            let plan = call.cwd.appendingPathComponent("plan.md")
            try! "# Plan\n\n## Scope\nOne, everywhere\n".write(to: plan, atomically: true, encoding: .utf8)
            return ok(call, "int", json(IntegrateOutput(agree: 1, somewhat: 0, disagree: 0, notes: "applied")))
        }
        let tape = try refineTape()
        try writeUserEdits(editedPlan, checkpoint: 2)
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                    inputs(config(), tape: tape)))
        XCTAssertTrue(cp.record.note?.contains("1 of your edited lines was changed by this round.") ?? false,
                      cp.record.note ?? "nil")
    }

    /// Synthesis builds on the draft checkpoint's effective plan — the human's edit of the
    /// first draft — and still sees the other drafts.
    func testSynthesisBuildsOnTheEditedDraft() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "synthesizer" ? ok(call, "syn", self.review(1)) : self.editingIntegrator(call)
        }
        let tape = try synthesisTape()
        try writeUserEdits(editedPlan, checkpoint: 1)
        let (_, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .synthesis, round: 0, major: true),
                                                                       inputs(config(), tape: tape)))
        XCTAssertEqual(text(files["plan.md"]), editedPlan + "\n## Added\nnew line\n")
        let synth = try XCTUnwrap(runner.calls("synthesizer").first).prompt
        XCTAssertTrue(synth.contains("The draft at \(store.userEditsURL(checkpoint: 1).path) (yours to revise)"), synth)
        XCTAssertTrue(synth.contains(store.checkpointDirectory(1).appendingPathComponent("drafts/1.md").path))
        XCTAssertTrue(synth.contains("These edits are authoritative"))
    }

    /// Encode copies the effective plan into its own checkpoint, so the edits become plan.
    func testEncodeCarriesTheEditedPlanForward() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in ok(call, "enc", self.changeSetReply(pre: self.existingPre)) }
        let tape = try refineTape()
        try writeUserEdits(editedPlan, checkpoint: 2)
        let (_, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .encode, round: 0, major: true),
                                                                       inputs(config(), tape: tape)))
        XCTAssertEqual(text(files["plan.md"]), editedPlan)
        XCTAssertTrue(try XCTUnwrap(runner.calls("encoder").first).prompt.contains("These edits are authoritative"))
    }

    /// Only the head's effective plan feeds a round: an edit to an older checkpoint is stored
    /// but changes nothing.
    func testEditToANonHeadCheckpointFeedsNothing() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "rev", self.review(1)) : self.editingIntegrator(call)
        }
        let tape = try refineTape()
        try writeUserEdits(editedPlan, checkpoint: 1)
        let (_, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                       inputs(config(), tape: tape)))
        XCTAssertEqual(text(files["plan.md"]), draftPlan + "\n## Added\nnew line\n")
        XCTAssertFalse(try XCTUnwrap(runner.calls("reviewer").first).prompt.contains("authoritative"))
    }

    /// Anchored notes reach the prompt as the numbered list, and the round records every note
    /// it consumed — anchors included.
    func testAnchoredNotesReachThePromptAndTheRecord() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "rev", self.review(1)) : self.editingIntegrator(call)
        }
        var tape = try refineTape()
        let note = PlanNote(kind: .mustChange, note: "say which platforms",
                            anchor: NoteAnchor(checkpoint: 2, quote: "One", section: "## Scope", prefix: "## Scope\n", suffix: "\n"))
        tape.pendingNotes = [note, PlanNote(note: "keep it small")]
        let (cp, _) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                    inputs(config(), tape: tape)))
        XCTAssertEqual(cp.record.annotations, tape.pendingNotes)
        let p = try XCTUnwrap(runner.calls("reviewer").first).prompt
        XCTAssertTrue(p.contains("1. [must change] in section \"## Scope\":\n   > One\n   This must change: say which platforms"), p)
        XCTAssertTrue(p.contains("The human steering this plan says:\n- keep it small"), p)
    }
}
