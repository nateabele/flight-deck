import XCTest
import IntakeKit

/// Plans are stored unwrapped from now on (`MarkdownUnwrap`), but a tape already mid-refine has
/// hard-wrapped checkpoints on disk that are never rewritten. Everything that compares two
/// plans — the edit layer, the carry-forward merge, churn, the prompt's edit diff — reads both
/// sides through the same unwrap, so a reflow is never a change and the wrap boundary between
/// an old checkpoint and a new one is invisible.
final class PlanUnwrapTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanUnwrapTests-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    var store: TapeStore { TapeStore(intakeDirectory: root) }

    func write(_ text: String, _ path: String, checkpoint: Int) throws {
        let url = store.checkpointDirectory(checkpoint).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A checkpoint recorded before plans were stored unwrapped.
    let wrapped = """
    # Plan

    ## Auth
    Sign in with OAuth through the
    system browser, never an embedded
    web view.

    ## Sync
    Poll the server every minute and
    back off on failure.

    ## Risks
    Token refresh races the first
    sync after launch.

    """

    var unwrapped: String { MarkdownUnwrap.unwrap(wrapped) }

    // MARK: - Layer reads

    func testLayerReadsOfAWrappedCheckpointComeBackUnwrapped() throws {
        try write(wrapped, "plan.md", checkpoint: 1)
        XCTAssertEqual(PlanLayers.generatedPlan(store.checkpointDirectory(1)), unwrapped)
        XCTAssertEqual(store.effectivePlan(checkpoint: 1), unwrapped)
        XCTAssertEqual(PlanLayers.readPlan(Data(wrapped.utf8)), unwrapped)
        XCTAssertEqual(try String(contentsOf: store.checkpointDirectory(1).appendingPathComponent("plan.md"), encoding: .utf8),
                       wrapped, "the recorded checkpoint on disk is never rewritten")
    }

    /// The human edits a wrapped checkpoint: the layer is stored unwrapped, and a save that only
    /// reflowed the text (what the editor sends back untouched) is no edit at all.
    func testUserLayerOverAWrappedCheckpointIsStoredUnwrapped() throws {
        try write(wrapped, "plan.md", checkpoint: 1)
        try store.writeUserEdits(checkpoint: 1, markdown: unwrapped)
        XCTAssertNil(store.userEdits(checkpoint: 1), "a reflow is not an edit")

        let edit = wrapped.replacingOccurrences(of: "Poll the server every minute and", with: "Push over a websocket and")
        try store.writeUserEdits(checkpoint: 1, markdown: edit)
        XCTAssertEqual(store.userEdits(checkpoint: 1), MarkdownUnwrap.unwrap(edit))
        let hunks = PlanLayers.userDiff(generated: try XCTUnwrap(PlanLayers.generatedPlan(store.checkpointDirectory(1))),
                                        edited: try XCTUnwrap(store.effectivePlan(checkpoint: 1)))
        XCTAssertEqual(hunks.map(\.newLines), [["Push over a websocket and back off on failure."]], "one edit, not every paragraph")
    }

    // MARK: - Carry-forward

    /// The round read a WRAPPED plan, the human edited it (still wrapped, as the old editor
    /// showed it), and the round's own output came back unwrapped with a change elsewhere. A
    /// line-based merge of those raw texts would see every paragraph changed on both sides.
    func testCarryForwardAcrossTheWrapBoundaryMergesCleanlyAndKeepsTheEdit() async throws {
        let base = wrapped
        let theirs = wrapped.replacingOccurrences(of: "system browser, never an embedded", with: "system browser or a passkey, never an embedded")
        let ours = unwrapped.replacingOccurrences(of: "Token refresh races the first sync after launch.",
                                                  with: "Token refresh races the first sync after launch; serialize them.")
        let carry = await PlanLayers.carryForward(ours: ours, base: base, theirs: theirs, runner: SystemCommandRunner(),
                                                  environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin"],
                                                  scratch: root.appendingPathComponent("carry"))
        guard case .merged(let plan) = carry else { return XCTFail("expected a clean merge, got \(carry)") }
        XCTAssertTrue(plan.contains("Sign in with OAuth through the system browser or a passkey, never an embedded web view.\n"), plan)
        XCTAssertTrue(plan.contains("serialize them."), plan)
        XCTAssertEqual(plan, MarkdownUnwrap.unwrap(plan), "the merged layer is stored unwrapped")
    }

    // MARK: - Churn

    func testChurnBetweenAWrappedAndAnUnwrappedCopyIsZero() {
        let files: [Int: [String: Data]] = [1: ["plan.md": Data(wrapped.utf8)], 2: ["plan.md": Data(unwrapped.utf8)]]
        let checkpoints = [Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: Date(timeIntervalSince1970: 0)),
                           Checkpoint(id: 2, parent: 1, stage: .refine, round: 1, major: false, createdAt: Date(timeIntervalSince1970: 0))]
        let churn = ConvergenceSeries.sectionChurn(checkpoints, loadFile: { files[$0]?[$1] })
        XCTAssertEqual(churn[2], [:], "a reflow is no churn")
    }

    // MARK: - Prompts

    /// Every seat that writes plan text — a whole draft, an `edit` for someone else to apply, or
    /// the integrated plan itself — is told not to hard-wrap it. Change-set seats write none.
    func testEverySeatThatWritesPlanTextIsToldNotToWrapIt() {
        let c = RoundContext(intent: "Ship it", qa: [], graphFile: "/i/graph.json", agentsFile: nil, readmeFile: nil,
                             observedAt: Date(timeIntervalSince1970: 0))
        let rule = "Write each paragraph and each list item as ONE line; never hard-wrap prose at a fixed width"
        for (name, prompt) in [("draft", RoundPrompts.draft(c, persona: .general)),
                               ("synthesis", RoundPrompts.synthesis(c, ownDraft: "/d/0.md", otherDrafts: ["/d/1.md"])),
                               ("review", RoundPrompts.review(c, planFile: "/p/plan.md", round: 1)),
                               ("integrate", RoundPrompts.integrate(planFile: "/w/plan.md", changesFile: "/w/changes.json"))] {
            XCTAssertTrue(prompt.contains(rule), "\(name): \(prompt)")
        }
        XCTAssertFalse(RoundPrompts.encode(c, planFile: "/p/plan.md").contains(rule))
    }

    // MARK: - Anchors

    /// A note made in the old wrapped text, its quote spanning what was a line break, still
    /// finds its passage in the unwrapped plan — in a paragraph, a list item and a quote.
    func testNoteQuotedAcrossAFormerLineBreakStillLocates() throws {
        let old = "## Auth\nSign in with OAuth through the\nsystem browser.\n\n- Retry the sync with\n  backoff.\n\n> Refresh races the\n> first sync.\n"
        let new = MarkdownUnwrap.unwrap(old)
        for (quote, expected) in [("the\nsystem browser", "the system browser"),
                                  ("sync with\n  backoff", "sync with backoff"),
                                  ("races the\n> first sync", "races the first sync")] {
            let range = try XCTUnwrap(old.range(of: quote))
            let anchor = NoteAnchor(checkpoint: 1, selecting: range, in: old)
            let found = try XCTUnwrap(anchor.locate(in: new), "\(quote) not found in \(new)")
            XCTAssertEqual(String(new[found]), expected)
        }
    }
}

// MARK: - Recording a round

extension RoundExecutorTests {
    /// A drafter that hard-wraps its plan is recorded unwrapped.
    func testDraftFromAWrappingSeatIsStoredUnwrapped() async throws {
        let runner = ScriptedHarnessRunner { call in
            ok(call, "s", json(DraftOutput(plan: "# Plan\n\nThe engine polls every\nminute.\n\n- one item that\n  wraps\n")))
        }
        let (_, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true),
                                                                       inputs(config())))
        XCTAssertEqual(text(files["drafts/0.md"]), "# Plan\n\nThe engine polls every minute.\n\n- one item that wraps\n")
    }

    /// Refining a checkpoint recorded wrapped: the integrator is handed the unwrapped plan, its
    /// own wrapped additions are joined, and the round's +/− counts only what it changed — not
    /// every paragraph the reflow touched.
    func testRefineOverAWrappedCheckpointStoresUnwrappedAndCountsOnlyItsChange() async throws {
        let wrappedPlan = "# Plan\n\n## Scope\nOne long sentence that\nwraps here.\n\n## Risks\nNone\nyet.\n"
        let staged = LockedBox<String>()
        let runner = ScriptedHarnessRunner { [unowned self] call in
            guard call.role == "integrator" else { return ok(call, "rev", self.review(1)) }
            let plan = call.cwd.appendingPathComponent("plan.md")
            let before = try! String(contentsOf: plan, encoding: .utf8)
            staged.set(before)
            try! (before + "\n## Added\nA new section that the\nintegrator wrapped.\n").write(to: plan, atomically: true, encoding: .utf8)
            return ok(call, "int", json(IntegrateOutput(agree: 1, somewhat: 0, disagree: 0, notes: "applied")))
        }
        var tape = try synthesisTape()
        try seed(&tape, .synthesis, files: ["plan.md": wrappedPlan])
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                                        inputs(config(), tape: tape)))
        let unwrappedPlan = "# Plan\n\n## Scope\nOne long sentence that wraps here.\n\n## Risks\nNone yet.\n"
        XCTAssertEqual(staged.value, unwrappedPlan, "the integrator edits the unwrapped plan")
        XCTAssertEqual(text(files["plan.md"]), unwrappedPlan + "\n## Added\nA new section that the integrator wrapped.\n")
        XCTAssertEqual(cp.record.linesAdded, 3)
        XCTAssertEqual(cp.record.linesRemoved, 0)
        XCTAssertEqual(cp.record.sectionsChanged, ["## Added"])
    }

    /// A human edit over a wrapped checkpoint reaches the prompt as that one edit, not as a diff
    /// of every paragraph.
    func testEditsOverAWrappedCheckpointReachThePromptAsOnlyTheEdit() async throws {
        let wrappedPlan = "# Plan\n\n## Scope\nOne long sentence that\nwraps here.\n\n## Risks\nNone\nyet.\n"
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "rev", self.review(1)) : self.editingIntegrator(call)
        }
        var tape = try synthesisTape()
        try seed(&tape, .synthesis, files: ["plan.md": wrappedPlan,
                                            "plan.user.md": "# Plan\n\n## Scope\nOne long sentence that wraps here, Mac only.\n\n## Risks\nNone yet.\n"])
        _ = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 1, major: false),
                                                         inputs(config(), tape: tape)))
        let prompt = try XCTUnwrap(runner.calls("reviewer").first).prompt
        XCTAssertTrue(prompt.contains("-One long sentence that wraps here.\n+One long sentence that wraps here, Mac only."), prompt)
        XCTAssertFalse(prompt.contains("-None"), "the untouched paragraph is not in the diff: \(prompt)")
    }
}

/// A value a `@Sendable` script closure can hand back to the test.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ v: T) { lock.lock(); stored = v; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}
