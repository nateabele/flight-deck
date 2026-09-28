import Foundation

/// Everything one round needs from outside: the intake (intent, Q&A), its round config, the
/// tape as it stands (to find the current plan / change set and number the checkpoint), where
/// the intake's files live, and the COMPLETE child environment (PATH already resolved — see
/// `CommandRunner.run`). `now` is injected so a test can pin `graphObservedAt`.
public struct RoundInputs: Sendable {
    public var intake: Intake
    public var config: RoundConfig
    public var tape: Tape
    public var store: TapeStore
    public var project: URL
    public var environment: [String: String]
    public var now: @Sendable () -> Date
    public init(intake: Intake, config: RoundConfig, tape: Tape, store: TapeStore, project: URL,
                environment: [String: String], now: @escaping @Sendable () -> Date = { Date() }) {
        self.intake = intake; self.config = config; self.tape = tape; self.store = store
        self.project = project; self.environment = environment; self.now = now
    }
}

public enum RoundResult: Sendable {
    /// `files` are keyed by relative path inside `checkpoints/<id>/` (e.g. `drafts/0.md`); the
    /// runner writes them and appends the checkpoint — `RoundExecutor` never touches the tape.
    case checkpoint(Checkpoint, files: [String: Data])
    case paused(Diagnosis, partialRecord: RoundRecord)
}

/// `runs/<name>/run.json`: written before the child spawns (pid nil), rewritten with the pid
/// the moment it exists, and again on exit — so a runner that crashed mid-round leaves behind
/// a pid a restart can check for (and reap) instead of an orphan nobody knows about. Its
/// siblings (`stdout`, `stderr`, `activity.json`) are described on `TapeStore`.
public struct RunRecord: Codable, Equatable, Sendable {
    public var pid: Int32?
    public var sessionID: String?
    public var started: Date
    public var finished: Date?
    public var exitCode: Int32?
    public init(pid: Int32? = nil, sessionID: String? = nil, started: Date, finished: Date? = nil, exitCode: Int32? = nil) {
        self.pid = pid; self.sessionID = sessionID; self.started = started
        self.finished = finished; self.exitCode = exitCode
    }
}

/// Runs one planned round end to end — harness children, integrator edits, validation and its
/// single correction turn — and hands back either a checkpoint to append or a diagnosis to
/// pause on. Deliberately free of tape writes: the runner (Task 8) owns `tape.json` and
/// `checkpoints/`, this only writes scratch under `runs/` and `work/`, so a round that pauses
/// or is cancelled halfway leaves the tape exactly as it was.
public struct RoundExecutor: Sendable {
    private let runner: CommandRunner
    private let graphReader: GraphReader
    private let userHome: URL
    private let bvPath: String

    /// `userHome` is where `ClaudeUserEnv` looks for `.claude/settings.json` and
    /// `CodexUserConfig` for `.codex/config.toml` — injectable so a test never depends on (or
    /// leaks) the operator's own settings. `bvPath` mirrors `GraphReader`/`ShadowGraph`'s
    /// `brPath`: FD runs `bv` itself against a polish round's shadow (never the agent — see
    /// `ShadowAnalytics`'s doc comment), so the same injectability that already covers `br` and
    /// the harnesses covers it too.
    public init(runner: CommandRunner, graphReader: GraphReader,
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser, bvPath: String = "bv") {
        self.runner = runner
        self.graphReader = graphReader
        self.userHome = userHome
        self.bvPath = bvPath
    }

    /// Throws only `CancellationError` (⏹); every other failure — a harness that died, prose
    /// where JSON belonged, a disk error — comes back as `.paused` so the human sees why.
    public func run(_ planned: PlannedRound, _ inputs: RoundInputs) async throws -> RoundResult {
        // Every stage's prompt carries the pending notes (see `context`), so every stage
        // consumes them, and the runner can clear exactly what the checkpoint records.
        var record = RoundRecord(annotations: inputs.tape.pendingNotes)
        let files: [String: Data]
        do {
            try FileManager.default.createDirectory(at: inputs.store.workDirectory(), withIntermediateDirectories: true)
            switch planned.stage {
            case .draft: files = try await draft(planned, inputs, &record)
            case .synthesis: files = try await synthesis(planned, inputs, &record)
            case .refine: files = try await refine(planned, inputs, &record)
            case .encode: files = try await encode(planned, inputs, &record)
            case .polish, .freshEyes, .dedup: files = try await polish(planned, inputs, &record)
            }
        } catch let pause as Pause {
            return .paused(pause.diagnosis, partialRecord: record)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .paused(Diagnosis(category: .harnessError, detail: "\(error)", action: "Retry the round."),
                           partialRecord: record)
        }
        let head = inputs.tape.head
        let cp = Checkpoint(id: (head?.id ?? 0) + 1, parent: head?.id, stage: planned.stage, round: planned.round,
                            major: planned.major, createdAt: inputs.now(), record: record)
        return .checkpoint(cp, files: files)
    }

    // MARK: - Stages

    /// Every drafter at once; a drafter that fails gets its slot's fallback exactly once, and
    /// one that still fails is recorded and skipped — a draft round only pauses when there is
    /// no draft at all to carry forward.
    private func draft(_ planned: PlannedRound, _ inputs: RoundInputs, _ record: inout RoundRecord) async throws -> [String: Data] {
        guard !inputs.config.drafters.isEmpty else { throw Pause.config("no drafters") }
        let (_, graphFile, observedAt) = try await readGraph(inputs)
        let ctx = context(inputs, graphFile: graphFile, observedAt: observedAt)
        let work = inputs.store.workDirectory()

        let results = try await withThrowingTaskGroup(of: (Int, SlotOutcome, String?).self) { group in
            for (i, slot) in inputs.config.drafters.enumerated() {
                group.addTask {
                    let prompt = RoundPrompts.draft(ctx, persona: slot.persona)
                    let name = runName(planned, "drafter", i)
                    func attemptDraft(_ choice: ModelChoice, _ name: String) async throws -> Attempt<DraftOutput> {
                        try await attempt(DraftOutput.self, name, choice, prompt: prompt, schema: RoundSchemas.draft,
                                          cwd: inputs.project, readable: [work], inputs: inputs)
                    }
                    switch try await attemptDraft(slot.choice, name) {
                    case .ok(let out, let session):
                        return (i, SlotOutcome(role: "drafter", persona: slot.persona, used: slot.choice, requested: slot.choice,
                                               status: .ok, sessionID: session), out.plan)
                    case .failed(let firstDiagnosis, _):
                        guard let fallback = slot.fallback else {
                            return (i, SlotOutcome(role: "drafter", persona: slot.persona, used: slot.choice,
                                                   requested: slot.choice, status: .failed, diagnosis: firstDiagnosis), nil)
                        }
                        switch try await attemptDraft(fallback, name + "-fallback") {
                        case .ok(let out, let session):
                            return (i, SlotOutcome(role: "drafter", persona: slot.persona, used: fallback, requested: slot.choice,
                                                   status: .substituted, sessionID: session), out.plan)
                        case .failed(let diagnosis, _):
                            return (i, SlotOutcome(role: "drafter", persona: slot.persona, used: fallback,
                                                   requested: slot.choice, status: .failed, diagnosis: diagnosis), nil)
                        }
                    }
                }
            }
            var all: [(Int, SlotOutcome, String?)] = []
            for try await r in group { all.append(r) }
            return all.sorted { $0.0 < $1.0 }
        }

        record.slots = results.map(\.1)
        let drafts = results.compactMap { i, _, plan in plan.map { (i, $0) } }
        guard !drafts.isEmpty else {
            throw Pause(diagnosis: results[0].1.diagnosis
                        ?? Diagnosis(category: .harnessError, detail: "every drafter failed", action: "Retry, or change the drafters."))
        }
        return Dictionary(uniqueKeysWithValues: drafts.map { ("drafts/\($0.0).md", Data($0.1.utf8)) })
    }

    /// The synthesizer proposes edits to the first surviving draft in light of the others; the
    /// integrator applies them. Its base is drafter 0's draft whenever drafter 0 succeeded.
    private func synthesis(_ planned: PlannedRound, _ inputs: RoundInputs, _ record: inout RoundRecord) async throws -> [String: Data] {
        guard let synthesizer = inputs.config.synthesizer else { throw Pause.config("no synthesizer") }
        let drafts = try draftFiles(inputs)
        // The draft checkpoint's effective plan: drafter 0's draft, or the human's edit of it.
        let base = try currentPlan(inputs)
        let work = inputs.store.workDirectory()
        let ctx = context(inputs, graphFile: work.appendingPathComponent("graph.json"), observedAt: inputs.now())
        let prompt = RoundPrompts.synthesis(ctx, ownDraft: base.path, otherDrafts: drafts.dropFirst().map(\.path))
        let review = try await seat(ReviewOutput.self, planned, "synthesizer", persona: synthesizer.persona,
                                    synthesizer.choice, prompt: prompt, schema: RoundSchemas.review, cwd: inputs.project,
                                    readable: [base.deletingLastPathComponent(), work], inputs: inputs, &record)
        return try await integrate(review, base: base, ctx: ctx, planned, inputs, &record)
    }

    /// A fresh reviewer every round — never a resume — so round N isn't anchored on what the
    /// same session already said in round N-1; that independence is the point of refining.
    private func refine(_ planned: PlannedRound, _ inputs: RoundInputs, _ record: inout RoundRecord) async throws -> [String: Data] {
        guard let reviewer = inputs.config.reviewer else { throw Pause.config("no reviewer") }
        let plan = try currentPlan(inputs)
        let work = inputs.store.workDirectory()
        let ctx = context(inputs, graphFile: work.appendingPathComponent("graph.json"), observedAt: inputs.now())
        let review = try await seat(ReviewOutput.self, planned, "reviewer", reviewer.choice,
                                    prompt: RoundPrompts.review(ctx, planFile: plan.path, round: planned.round),
                                    schema: RoundSchemas.review, cwd: inputs.project,
                                    readable: [plan.deletingLastPathComponent(), work], inputs: inputs, &record)
        return try await integrate(review, base: plan, ctx: ctx, planned, inputs, &record)
    }

    /// Shared tail of synthesis and refine: stage `base` and the proposed changes in `work/`,
    /// let the integrator edit `work/plan.md` in place, and measure what it actually did.
    private func integrate(_ review: ReviewOutput, base: URL, ctx: RoundContext, _ planned: PlannedRound,
                           _ inputs: RoundInputs, _ record: inout RoundRecord) async throws -> [String: Data] {
        let work = inputs.store.workDirectory()
        let planFile = work.appendingPathComponent("plan.md"), changesFile = work.appendingPathComponent("changes.json")
        let before = try Data(contentsOf: base)
        // Nothing proposed means nothing to apply: running an integrator anyway costs a model
        // turn and can only drift the plan. The round still lands, so the tape shows a
        // reviewer that found nothing — the signal refinement has converged.
        guard !review.changes.isEmpty else {
            record.changeCount = 0
            record.note = review.summary.isEmpty ? nil : review.summary
            return ["plan.md": before]
        }
        try IntakeJSON.encoder.encode(review.changes).write(to: changesFile, options: .atomic)
        try before.write(to: planFile, options: .atomic)

        // cwd IS the work dir — never the project: codex's workspace-write sandbox is rooted at
        // cwd, so a project cwd would let the integrator edit the user's repo.
        let tally = try await seat(IntegrateOutput.self, planned, "integrator", inputs.config.integrator,
                                   prompt: RoundPrompts.integrate(planFile: planFile.path, changesFile: changesFile.path,
                                                                  humanEdits: ctx.humanEdits),
                                   schema: RoundSchemas.integrate, cwd: work, readable: [], access: .writeInWork(work),
                                   inputs: inputs, &record)
        let after = try Data(contentsOf: planFile)
        record.changeCount = review.changes.count
        record.tally = VerdictTally(agree: tally.agree, somewhat: tally.somewhat, disagree: tally.disagree)
        var notes = [review.summary, tally.notes]
        // A tally that doesn't add up is worth showing, not worth pausing over: the plan edit is
        // what matters, and the integrator's arithmetic is only a summary of it.
        let verdicts = tally.agree + tally.somewhat + tally.disagree
        if verdicts != review.changes.count {
            notes.append("The integrator tallied \(verdicts) verdicts for \(review.changes.count) proposed changes.")
        }
        // The human's edits were declared authoritative; a round that rewrote them anyway is
        // worth a warning on the card, not a pause — the human decides whether to re-apply.
        if let edits = userEdits(inputs) {
            let lost = PlanLayers.lostEditedLines(generated: edits.generated, edited: edits.edited,
                                                  in: String(decoding: after, as: UTF8.self))
            if lost > 0 {
                notes.append("\(lost) of your edited lines \(lost == 1 ? "was" : "were") changed by this round.")
            }
        }
        record.note = notes.filter { !$0.isEmpty }.joined(separator: "\n\n")
        // An integrator that claims it applied changes but left the file untouched has either
        // edited some other path or hallucinated its report — either way the next round would
        // silently build on a plan that never moved.
        if after == before, tally.agree + tally.somewhat > 0 {
            record.slots[record.slots.count - 1].status = .failed
            let diagnosis = Diagnosis(category: .invalidOutput, detail: "integrator reported changes but did not edit the plan",
                                      action: "Retry the round, or switch the integrator's model.")
            record.slots[record.slots.count - 1].diagnosis = diagnosis
            throw Pause(diagnosis: diagnosis)
        }
        let delta = PlanMetrics.delta(from: String(decoding: before, as: UTF8.self), to: String(decoding: after, as: UTF8.self))
        record.linesAdded = delta.added
        record.linesRemoved = delta.removed
        record.sectionsChanged = delta.sectionsChanged
        return ["plan.md": after]
    }

    private func encode(_ planned: PlannedRound, _ inputs: RoundInputs, _ record: inout RoundRecord) async throws -> [String: Data] {
        let plan = try currentPlan(inputs)
        let (graph, graphFile, observedAt) = try await readGraph(inputs)
        let ctx = context(inputs, graphFile: graphFile, observedAt: observedAt)
        let cs = try await changeSetSeat(planned, "encoder", inputs.config.encoder,
                                         prompt: RoundPrompts.encode(ctx, planFile: plan.path),
                                         readable: [plan.deletingLastPathComponent(), inputs.store.workDirectory()],
                                         graph: graph, observedAt: observedAt, inputs: inputs, &record)
        record.changeCount = cs.ops.count
        return ["changeset.json": try cs.encoded(), "plan.md": try Data(contentsOf: plan),
                "graph.json": try IntakeJSON.encoder.encode(graph)]
    }

    /// Polish, fresh-eyes and dedup: each hands back a whole revised change set, held to the
    /// same validation (and single correction turn) encode is — but against the graph ENCODE
    /// saw, carried forward in every checkpoint since (read fresh only when no checkpoint has
    /// one). A bead that moves after encode is drift, and drift is release's job (it rechecks every `pre`); validating
    /// against a fresh graph here would instead pause polish on a `pre` the polisher was told
    /// to keep exactly as it was. `graphObservedAt` stays that snapshot's time for the same
    /// reason: release measures drift from when the graph was read, not from the last polish.
    private func polish(_ planned: PlannedRound, _ inputs: RoundInputs, _ record: inout RoundRecord) async throws -> [String: Data] {
        guard let polisher = inputs.config.polisher else { throw Pause.config("no polisher") }
        let plan = try currentPlan(inputs)
        guard let current = latestFile("changeset.json", inputs) else {
            throw Pause(diagnosis: Diagnosis(category: .harnessError, detail: "no change set to \(planned.stage.rawValue)",
                                             action: "Run the encode round first."))
        }
        let old = try ChangeSet.decode(Data(contentsOf: current))
        let graph: GraphSnapshot, graphData: Data, observedAt: Date
        var fallbackNote: String?
        if let snapshot = latestFile("graph.json", inputs) {
            graphData = try Data(contentsOf: snapshot)
            graph = try IntakeJSON.decoder.decode(GraphSnapshot.self, from: graphData)
            observedAt = old.graphObservedAt
        } else {
            // No snapshot to carry (an encode from before snapshots were saved). Never pause
            // here: a pause writes no checkpoint, so the planner would hand back this same
            // round and ⏯ would loop on it forever. Read once, and this round's graph.json
            // becomes the snapshot every later round carries.
            (graph, _, observedAt) = try await readGraph(inputs)
            graphData = try IntakeJSON.encoder.encode(graph)
            fallbackNote = "no encode graph snapshot; read the graph fresh"
        }
        let work = inputs.store.workDirectory()
        let changeSetFile = work.appendingPathComponent("changeset.json"), graphFile = work.appendingPathComponent("graph.json")
        try old.encoded().write(to: changeSetFile, options: .atomic)
        try graphData.write(to: graphFile, options: .atomic)
        let ctx = context(inputs, graphFile: graphFile, observedAt: observedAt)

        // A shadow copy of `old` — the change set THIS round starts from, never whatever the
        // polisher goes on to propose — so FD can run `bv`'s robot reports against the graph as
        // if it had already landed and hand the agent the resulting files. Both the shadow and
        // the `bv` runs are aids, not gates: either one failing only drops the analytics
        // guidance from the prompt and folds a note into `record.note` below, never a `Pause`.
        let (analytics, shadowNote) = await buildShadowAnalytics(project: inputs.project, changeSet: old, in: work, inputs: inputs)
        let prompt: String
        switch planned.stage {
        case .freshEyes:
            prompt = RoundPrompts.freshEyes(ctx, planFile: plan.path, changeSetFile: changeSetFile.path, analytics: analytics)
        case .dedup:
            prompt = RoundPrompts.dedup(ctx, changeSetFile: changeSetFile.path, analytics: analytics)
        default:
            prompt = RoundPrompts.polish(ctx, planFile: plan.path, changeSetFile: changeSetFile.path, round: planned.round,
                                         analytics: analytics)
        }
        let cs = try await changeSetSeat(planned, "polisher", polisher, prompt: prompt,
                                         readable: [plan.deletingLastPathComponent(), work],
                                         graph: graph, observedAt: observedAt, inputs: inputs, &record)
        record.changeCount = PlanMetrics.opsChanged(from: old, to: cs)
        // Both notes are independent aids, not gates, and either or both can be nil: the graph
        // snapshot fallback (no encode checkpoint to carry one) and the shadow/bv analytics
        // failure note (Task 7b) can each fire on their own round.
        record.note = [fallbackNote, record.note, shadowNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return ["changeset.json": try cs.encoded(), "plan.md": try Data(contentsOf: plan), "graph.json": graphData]
    }

    /// `bv`'s three robot reports, run by FD ITSELF against a fresh shadow of `changeSet` and
    /// written under `work/` as plain files for the polisher to read. No claude seat is ever
    /// granted `bv` (see `ShadowAnalytics`'s doc comment for why a scoped `--db` allow still
    /// isn't safe), so this is the only way the guidance reaches the prompt. Returns `nil` with
    /// a "… unavailable: …" note on any failure — building the shadow, running `bv`, or writing
    /// its output — since the analytics are an aid, not a gate; nothing here ever throws.
    private func buildShadowAnalytics(project: URL, changeSet: ChangeSet, in work: URL,
                                      inputs: RoundInputs) async -> (ShadowAnalytics?, String?) {
        let shadow = ShadowGraph(runner: runner, environment: inputs.environment)
        let shadowDir = work.appendingPathComponent("shadow", isDirectory: true)
        let shadowBeads: URL
        do {
            shadowBeads = try await shadow.build(project: project, changeSet: changeSet, in: shadowDir)
        } catch let failure as ShadowGraphBuildFailed {
            return (nil, "shadow graph unavailable: \(failure.detail)")
        } catch {
            return (nil, "shadow graph unavailable: \(error)")
        }

        // Every `bv` call runs with `cwd` = `shadowDir`, never `project`, for the same reason
        // `ShadowGraph` never lets `br` run with `cwd` = `project`: `bv` also auto-discovers a
        // `.beads` from `cwd` when `--db` is absent, and a call that fell back to that here
        // would silently read the real graph instead of the shadow.
        let runs: [(flag: String, filename: String)] = [("--robot-insights", "bv-insights.json"),
                                                        ("--robot-plan", "bv-plan.json"),
                                                        ("--robot-priority", "bv-priority.json")]
        var paths: [String: String] = [:]
        for run in runs {
            let result: CommandResult
            do {
                result = try await runner.run(executable: bvPath,
                    arguments: ["--db", shadowBeads.path, run.flag, "--format", "json", "--no-hooks"],
                    cwd: shadowDir, environment: inputs.environment)
            } catch {
                return (nil, "bv analytics unavailable: \(run.flag): \(error)")
            }
            guard result.exitCode == 0 else {
                let stderr = String(decoding: result.stdout, as: UTF8.self).prefix(200)
                return (nil, "bv analytics unavailable: \(run.flag) exit \(result.exitCode): \(stderr)")
            }
            let path = work.appendingPathComponent(run.filename)
            do {
                try result.stdout.write(to: path, options: .atomic)
            } catch {
                return (nil, "bv analytics unavailable: could not write \(run.filename): \(error)")
            }
            paths[run.filename] = path.path
        }
        return (ShadowAnalytics(insights: paths["bv-insights.json"]!, plan: paths["bv-plan.json"]!,
                                priority: paths["bv-priority.json"]!), nil)
    }

    /// One change-set seat: run it, stamp FD's own `graphObservedAt` (the agent's clock is not
    /// the one release drift-checks against), validate, and on failure resume the SAME session
    /// once with the errors listed — the same one-retry rule triage follows (spec §11), in
    /// words that ask for a `{changeSet, summary}` rather than triage's "recommendation".
    private func changeSetSeat(_ planned: PlannedRound, _ role: String, _ choice: ModelChoice, prompt: String,
                               readable: [URL], graph: GraphSnapshot, observedAt: Date,
                               inputs: RoundInputs, _ record: inout RoundRecord) async throws -> ChangeSet {
        var first = try await seat(ChangeSetOutput.self, planned, role, choice, prompt: prompt, schema: RoundSchemas.changeSet,
                                   cwd: inputs.project, readable: readable, inputs: inputs, &record)
        first.changeSet.graphObservedAt = observedAt
        record.note = first.summary
        guard case .failure(let errors) = ChangeSetValidator.validate(first.changeSet, against: graph) else {
            return first.changeSet
        }
        let slot = record.slots.count - 1
        let correction = RoundPrompts.changeSetCorrection(errors: errors.errors, observedAt: observedAt)
        switch try await attempt(ChangeSetOutput.self, runName(planned, role) + "-correction", choice, prompt: correction,
                                 schema: RoundSchemas.changeSet, cwd: inputs.project, readable: readable,
                                 resume: record.slots[slot].sessionID, inputs: inputs) {
        case .failed(let diagnosis, _):
            record.slots[slot].status = .failed
            record.slots[slot].diagnosis = diagnosis
            throw Pause(diagnosis: diagnosis)
        case .ok(var second, let session):
            record.slots[slot].sessionID = session
            second.changeSet.graphObservedAt = observedAt
            record.note = second.summary
            if case .failure(let again) = ChangeSetValidator.validate(second.changeSet, against: graph) {
                let diagnosis = Diagnosis(
                    category: .invalidOutput,
                    detail: "The change set failed validation twice: " + again.errors.map(\.message).joined(separator: "; "),
                    action: "Retry the round, or switch this slot's model.")
                record.slots[slot].status = .failed
                record.slots[slot].diagnosis = diagnosis
                throw Pause(diagnosis: diagnosis)
            }
            return second.changeSet
        }
    }

    // MARK: - Seats

    private enum Attempt<T: Sendable>: Sendable {
        case ok(T, sessionID: String)
        case failed(Diagnosis, sessionID: String?)
    }

    /// A non-drafter seat: records its `SlotOutcome` either way, and pauses the round on
    /// failure — only drafters get a fallback, every other role is a single point the human
    /// has to look at.
    private func seat<T: Decodable & Sendable>(_ type: T.Type, _ planned: PlannedRound, _ role: String,
                                               persona: DrafterPersona? = nil, _ choice: ModelChoice, prompt: String,
                                               schema: String, cwd: URL, readable: [URL],
                                               access: HarnessAccess = .readOnly,
                                               inputs: RoundInputs, _ record: inout RoundRecord) async throws -> T {
        switch try await attempt(type, runName(planned, role), choice, prompt: prompt, schema: schema, cwd: cwd,
                                 readable: readable, access: access, inputs: inputs) {
        case .ok(let value, let session):
            record.slots.append(SlotOutcome(role: role, persona: persona, used: choice, requested: choice,
                                            status: .ok, sessionID: session))
            return value
        case .failed(let diagnosis, let session):
            record.slots.append(SlotOutcome(role: role, persona: persona, used: choice, requested: choice,
                                            status: .failed, diagnosis: diagnosis, sessionID: session))
            throw Pause(diagnosis: diagnosis)
        }
    }

    /// One harness turn in its own `runs/<name>/`, parsed and decoded. Model and effort are
    /// always passed explicitly (a codex resume otherwise falls back to its config default).
    private func attempt<T: Decodable & Sendable>(_ type: T.Type, _ name: String, _ choice: ModelChoice, prompt: String,
                                                  schema: String, cwd: URL, readable: [URL],
                                                  access: HarnessAccess = .readOnly,
                                                  resume: String? = nil, inputs: RoundInputs) async throws -> Attempt<T> {
        try Task.checkCancellation()
        let dir = inputs.store.runDirectory(name)
        let fm = FileManager.default
        // A retried round reuses its run names; the dead attempt's streams must not be mistaken
        // for this one's.
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let schemaFile = dir.appendingPathComponent("schema.json")
        try Data(schema.utf8).write(to: schemaFile, options: .atomic)

        let request = HarnessRequest(harness: choice.harness, model: choice.model, effort: choice.effort, cwd: cwd,
                                     readableDirs: readable, prompt: prompt, schemaFile: schemaFile, schemaJSON: schema,
                                     resumeSessionID: resume, access: access)
        // `build` traps on an invalid write-mode request; checking first turns a wiring bug
        // into a paused round instead of a crashed runner.
        if let invalid = HarnessCommand.validate(request) {
            return .failed(Diagnosis(category: .harnessError, detail: "invalid harness request: \(invalid)",
                                     action: "This is a Flight Deck bug — report it."), sessionID: nil)
        }
        let command = HarnessCommand.build(request, home: userHome)
        let environment = HarnessCommand.environment(for: command, base: inputs.environment, home: userHome)

        // stdout is appended live, chunk by chunk as the child writes it, so the stream on disk
        // is never more than a pipe read behind the child — the runner's reader thread is the
        // file's single writer, and nothing ever rewrites it. The same chunks feed the seat's
        // `activity.json` (see `ActivityPublisher`).
        let stdoutFile = dir.appendingPathComponent("stdout")
        guard fm.createFile(atPath: stdoutFile.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: stdoutFile.path])
        }
        let stream = try FileHandle(forWritingTo: stdoutFile)
        defer { try? stream.close() }
        let activity = ActivityPublisher(harness: choice.harness, project: inputs.project, cwd: cwd,
                                         destination: dir.appendingPathComponent("activity.json"), now: inputs.now)
        activity.start()

        let runFile = dir.appendingPathComponent("run.json")
        let started = inputs.now()
        let pid = PIDBox()
        try Self.write(RunRecord(started: started), to: runFile)
        let result: CommandResult
        do {
            result = try await runner.run(executable: command.executable, arguments: command.arguments, cwd: cwd,
                                          environment: environment, processGroup: true,
                                          onSpawn: { spawned in
                                              pid.set(spawned)
                                              try? Self.write(RunRecord(pid: spawned, started: started), to: runFile)
                                          },
                                          onStdout: { chunk in
                                              try? stream.write(contentsOf: chunk)
                                              activity.feed(chunk)
                                          })
        } catch is CancellationError {
            try? Self.write(RunRecord(pid: pid.value, started: started, finished: inputs.now()), to: runFile)
            activity.finish(exitCode: nil)
            throw CancellationError()
        } catch {
            try? Self.write(RunRecord(pid: pid.value, started: started, finished: inputs.now()), to: runFile)
            activity.finish(exitCode: nil, error: "Could not run \(command.executable)")
            return .failed(Diagnosis(category: .harnessError, detail: "Could not run \(command.executable): \(error)",
                                     action: "Check that \(command.executable) is installed, then retry."), sessionID: nil)
        }
        activity.finish(exitCode: result.exitCode)
        var session: String?
        var outcome: Attempt<T>
        do {
            guard result.exitCode == 0 else { throw NonZeroExit() }
            let parsed = try HarnessOutput.parse(choice.harness, stdout: result.stdout)
            session = parsed.sessionID
            do {
                outcome = .ok(try RoundPrompts.decode(type, parsed.structured), sessionID: parsed.sessionID)
            } catch {
                // Classified against the error alone, not stdout: a plan that merely MENTIONS
                // "401" or "rate limit" must not read as an auth or quota failure.
                outcome = .failed(FailureDiagnosis.classify(exitCode: 0, stdout: Data(), stderr: "", parseError: error,
                                                            harness: choice.harness), sessionID: parsed.sessionID)
            }
        } catch {
            outcome = .failed(FailureDiagnosis.classify(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
                                                        parseError: error is NonZeroExit ? nil : error, harness: choice.harness),
                              sessionID: nil)
        }
        // The finished record goes down BEFORE stderr: a write that fails would otherwise
        // leave a pid with no `finished`, which a restart's reaper reads as a child still
        // alive — and might signal whatever process has since reused that pid.
        try Self.write(RunRecord(pid: pid.value, sessionID: session, started: started, finished: inputs.now(),
                                 exitCode: result.exitCode), to: runFile)
        try Data(result.stderr.utf8).write(to: dir.appendingPathComponent("stderr"), options: .atomic)
        return outcome
    }

    private struct NonZeroExit: Error {}

    private static func write(_ run: RunRecord, to url: URL) throws {
        try IntakeJSON.encoder.encode(run).write(to: url, options: .atomic)
    }

    // MARK: - Inputs

    /// Read the live graph fresh and write it to `work/graph.json` for the seat to read.
    /// `observedAt` is taken BEFORE the read, so a bead that changes during it is judged newer
    /// than the snapshot rather than silently older.
    private func readGraph(_ inputs: RoundInputs) async throws -> (GraphSnapshot, URL, Date) {
        let observedAt = inputs.now()
        let graph: GraphSnapshot
        do { graph = try await graphReader.read(project: inputs.project.path) }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw Pause(diagnosis: Diagnosis(category: .harnessError, detail: "Could not read the bead graph: \(error)",
                                             action: "Check that `br` works in the project, then retry the round."))
        }
        let file = inputs.store.workDirectory().appendingPathComponent("graph.json")
        try IntakeJSON.encoder.encode(graph).write(to: file, options: .atomic)
        return (graph, file, observedAt)
    }

    private func context(_ inputs: RoundInputs, graphFile: URL, observedAt: Date) -> RoundContext {
        // Only files that exist: listing a missing one sends the agent off to read it (see
        // `Triage.initialPrompt`'s doc).
        func existing(_ name: String) -> String? {
            let path = inputs.project.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        return RoundContext(intent: inputs.intake.intent, qa: inputs.intake.exchanges, graphFile: graphFile.path,
                            agentsFile: existing("AGENTS.md"), readmeFile: existing("README.md"),
                            notes: inputs.tape.pendingNotes,
                            humanEdits: userEdits(inputs).map { PlanLayers.promptDiff(generated: $0.generated, edited: $0.edited) },
                            observedAt: observedAt)
    }

    /// The head plan checkpoint's two layers when the human has edited it — read fresh each
    /// round, so an edit that landed between rounds is picked up by the next one. nil with no
    /// edit, and on a draft round (no plan yet).
    private func userEdits(_ inputs: RoundInputs) -> (generated: String, edited: String)? {
        guard let head = inputs.store.headPlanCheckpoint(in: inputs.tape),
              let edited = inputs.store.userEdits(checkpoint: head),
              let generated = PlanLayers.generatedPlan(inputs.store.checkpointDirectory(head)) else { return nil }
        return (generated, edited)
    }

    /// The newest checkpoint on the tape that has `relativePath` on disk.
    private func latestFile(_ relativePath: String, _ inputs: RoundInputs) -> URL? {
        inputs.tape.checkpoints.reversed().lazy
            .map { inputs.store.checkpointDirectory($0.id).appendingPathComponent(relativePath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The latest draft checkpoint's drafts in drafter order. A draft round records only the
    /// drafters that succeeded, so drafter 0's slot may be empty — the first surviving draft
    /// stands in for it.
    private func draftFiles(_ inputs: RoundInputs) throws -> [URL] {
        guard let cp = inputs.tape.checkpoints.last(where: { $0.stage == .draft }) else {
            throw Pause(diagnosis: Diagnosis(category: .harnessError, detail: "no draft checkpoint on the tape",
                                             action: "Run the draft round first."))
        }
        let dir = inputs.store.checkpointDirectory(cp.id).appendingPathComponent("drafts", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let drafts = names.compactMap { name -> (Int, URL)? in
            guard name.hasSuffix(".md"), let i = Int(name.dropLast(3)) else { return nil }
            return (i, dir.appendingPathComponent(name))
        }.sorted { $0.0 < $1.0 }.map(\.1)
        guard !drafts.isEmpty else {
            throw Pause(diagnosis: Diagnosis(category: .harnessError, detail: "checkpoint \(cp.id) has no drafts",
                                             action: "Re-run the draft round."))
        }
        return drafts
    }

    /// The head plan checkpoint's EFFECTIVE plan (`PlanLayers`): its `plan.user.md` when the
    /// human edited it, else its `plan.md`, else — a draft checkpoint, with no synthesis yet
    /// (Sketch) — the first surviving draft. Only the head counts: an edit to an older
    /// checkpoint is kept on disk but feeds nothing. Encode, polish, fresh-eyes and dedup copy
    /// this file into their own checkpoint's `plan.md`, so the edits carry forward as plan.
    private func currentPlan(_ inputs: RoundInputs) throws -> URL {
        guard let head = inputs.store.headPlanCheckpoint(in: inputs.tape),
              let url = PlanLayers.effectiveURL(inputs.store.checkpointDirectory(head)) else {
            throw Pause(diagnosis: Diagnosis(category: .harnessError, detail: "no plan on the tape",
                                             action: "Run the draft round first."))
        }
        return url
    }
}

/// `<stage>-<round>-<role>[-<i>]`, the `runs/` directory name for one harness child.
private func runName(_ planned: PlannedRound, _ role: String, _ index: Int? = nil) -> String {
    planned.runNamePrefix + role + (index.map { "-\($0)" } ?? "")
}

extension PlannedRound {
    /// What every one of this round's `runs/` directory names starts with — shared by
    /// `runName` and `TapeStore.activities(forRound:)` so the two can't disagree. The trailing
    /// dash keeps round 1 from also matching round 10.
    var runNamePrefix: String { "\(stage.rawValue)-\(round)-" }
}

/// Internal control flow: a seat failed in a way the human has to see. Caught in `run` and
/// turned into `.paused` together with whatever the record had collected so far.
private struct Pause: Error {
    let diagnosis: Diagnosis
    static func config(_ missing: String) -> Pause {
        Pause(diagnosis: Diagnosis(category: .harnessError, detail: "the round config has \(missing)",
                                   // A `.shaping` intake's config is fixed, so "edit the
                                   // config" was an action nobody could take from here.
                                   action: "Discard this intake and capture it again with a different fidelity, or with that seat filled in the Rounds editor."))
    }
}

/// The child's pid, set from `onSpawn` (another thread) and read after the run returns.
private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    func set(_ p: Int32) { lock.lock(); pid = p; lock.unlock() }
    var value: Int32? { lock.lock(); defer { lock.unlock() }; return pid }
}
