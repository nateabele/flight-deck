import Foundation
import IntakeKit

/// Which harness, model and effort run triage.
struct TriageSettings: Equatable, Sendable {
    var harness: Harness
    var model: String
    var effort: String

    // Detection-driven defaults: next plan (spec §6.2).
    static let codexDefault = TriageSettings(harness: .codex, model: "gpt-6-sol", effort: "high")
    static let claudeDefault = TriageSettings(harness: .claude, model: "opus", effort: "high")

    /// codex when a `codex` is on the login shell's PATH (what `which codex` would say in the
    /// user's own terminal), claude otherwise. Resolves `LoginShellPath`, which spawns a login
    /// shell on first use — call it off the main actor.
    static func detect(path: String? = LoginShellPath.repairing()["PATH"]) -> TriageSettings {
        let dirs = (path ?? "").split(separator: ":").map(String.init)
        let hasCodex = dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/codex") }
        return hasCodex ? codexDefault : claudeDefault
    }
}

/// What the release review sheet shows for one intake: every op's drift against the live
/// graph, and whether release is allowed yet.
struct ReleaseReview {
    var intake: Intake
    /// Parallel to `intake.changeSet!.ops`.
    var drift: [OpDrift]
    var summary: String
    /// False while any `.drifted` op is neither confirmed nor dropped — releasing it as
    /// triaged would write over a change someone made since (spec §5.5).
    var canRelease: Bool
}

/// Orchestrates intakes end to end (spec §4): capture → headless triage (with clarifying
/// Q&A) → recommendation/choice → release review → release (write to `br`, then deliver
/// notices). Every state change is persisted through `save(_:)` before it is published, so a
/// quit at any point leaves `intake.json` describing what actually happened.
@MainActor
final class IntakeService: ObservableObject {
    @Published private(set) var intakes: [Intake]

    private let store: IntakeStore
    private let headless: HeadlessRunner
    private let processRunner: FlywheelProcessRunner
    private let brPath: String, bvPath: String, amPath: String
    /// nil until first needed: detection spawns a login shell, which must not run on the
    /// main actor, and must not run at all in a session that never triages.
    private var triageSettings: TriageSettings?
    private let inject: (_ project: String, _ agent: String, _ text: String, _ token: UUID) -> Bool
    private let hasSession: (_ project: String, _ agent: String) -> Bool
    private let now: () -> Date

    /// At most one live triage/release per intake. Starting another cancels the first, so a
    /// retry or discard never races a turn whose result would overwrite the newer state.
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        store: IntakeStore,
        headless: HeadlessRunner = SystemHeadlessRunner(),
        processRunner: FlywheelProcessRunner = SystemFlywheelProcessRunner(),
        brPath: String = "br", bvPath: String = "bv", amPath: String = "am",
        triageSettings: TriageSettings? = nil,
        inject: @escaping (String, String, String, UUID) -> Bool,
        hasSession: @escaping (String, String) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.headless = headless
        self.processRunner = processRunner
        self.brPath = brPath; self.bvPath = bvPath; self.amPath = amPath
        self.triageSettings = triageSettings
        self.inject = inject
        self.hasSession = hasSession
        self.now = now

        // Launch recovery: a turn or release in flight when FD quit has no process left to
        // finish it. Saying "triaging" forever would hide that; `.interrupted` asks the human.
        var loaded = store.all()
        for i in loaded.indices where loaded[i].state == .triaging || loaded[i].state == .releasing {
            let was = loaded[i].state
            loaded[i].state = .interrupted
            loaded[i].failure = was == .releasing
                ? "Flight Deck quit during release; some beads may already be written — check `br list` before retrying."
                : "Flight Deck quit while triage was running."
            try? store.save(loaded[i])
        }
        intakes = loaded
    }

    // MARK: - Reads

    /// Newest first; discarded intakes are kept on disk but never listed.
    func intakes(forProject path: String) -> [Intake] {
        intakes.filter { $0.projectPath == path && $0.state != .discarded }
    }

    func attentionCount(forProject path: String) -> Int {
        intakes(forProject: path).filter(\.state.needsAttention).count
    }

    /// The live task for `id`, if any — so tests (and nothing else) can await a turn.
    func task(for id: UUID) -> Task<Void, Never>? { tasks[id] }

    // MARK: - Pipeline

    func capture(intent: String, project: String) {
        guard !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let intake = Intake(projectPath: project, intent: intent, createdAt: now())
        save(intake)
        start(intake.id) { await $0.runTriage(intake.id, turn: .initial) }
    }

    func answer(_ id: UUID, answers: [String]) {
        guard var i = intake(id), i.state == .needsAnswers, !i.exchanges.isEmpty else { return }
        i.exchanges[i.exchanges.count - 1].answers = answers
        save(i)
        let questions = i.exchanges[i.exchanges.count - 1].questions
        start(id) { await $0.runTriage(id, turn: .answers(questions: questions, answers: answers)) }
    }

    func choose(_ id: UUID, preset: Preset) {
        guard var i = intake(id), i.state == .awaitingChoice || i.state == .review else { return }
        guard preset == .bead else {
            // The round engine that shapes Sketch and above is the next plan; park, don't drop.
            i.state = .parked
            save(i)
            return
        }
        if i.changeSet != nil {
            i.state = .review
            save(i)
        } else {
            start(id) { await $0.runTriage(id, turn: .encodeNow) }
        }
    }

    func retry(_ id: UUID) {
        guard var i = intake(id), i.state == .failed || i.state == .interrupted else { return }
        // A fresh triage from the unchanged intent: the old session's context is what went
        // wrong (or is gone), and a re-read graph is the only safe base after an interrupted
        // release. The earlier Q&A goes with it — the agent will ask again if it still matters.
        i.recommended = nil; i.recommendationReason = nil; i.triage = nil; i.exchanges = []
        i.changeSet = nil; i.failure = nil; i.rawFailureOutput = nil
        i.ratingOverrides = [:]; i.droppedOps = []; i.confirmedDrift = []
        save(i)
        start(id) { await $0.runTriage(id, turn: .initial) }
    }

    func discard(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        guard var i = intake(id) else { return }
        i.state = .discarded
        save(i)
    }

    // MARK: - Release review

    func setRating(_ id: UUID, op: Int, _ r: DeliveryRating) {
        mutate(id) { $0.ratingOverrides[op] = r }
    }
    func drop(_ id: UUID, op: Int) {
        mutate(id) { $0.droppedOps.insert(op) }
    }
    func confirmDrift(_ id: UUID, op: Int) {
        mutate(id) { $0.confirmedDrift.insert(op) }
    }

    func reviewModel(_ id: UUID) async -> ReleaseReview? {
        guard let i = intake(id), let cs = i.changeSet,
              let triaged = triageGraph(id),
              case .success(let v) = ChangeSetValidator.validate(cs, against: triaged),
              let current = try? await graphReader.read(project: i.projectPath)
        else { return nil }
        let drift = DriftClassifier.classify(v, current: current)
        // Re-fetch: a rating/drop/confirm may have landed while the graph was being read.
        let latest = intake(id) ?? i
        return Self.review(latest, drift: drift)
    }

    static func review(_ i: Intake, drift: [OpDrift]) -> ReleaseReview {
        var drifted = 0, impossible = 0, unresolved = 0
        for (n, d) in drift.enumerated() {
            switch d {
            case .holds: break
            case .impossible: impossible += 1
            case .drifted:
                drifted += 1
                if !i.confirmedDrift.contains(n) && !i.droppedOps.contains(n) { unresolved += 1 }
            }
        }
        var parts = ["\(drift.count) op\(drift.count == 1 ? "" : "s")"]
        if drifted > 0 { parts.append("\(drifted) drifted") }
        if impossible > 0 { parts.append("\(impossible) impossible (dropped)") }
        if !i.droppedOps.isEmpty { parts.append("\(i.droppedOps.count) dropped") }
        if unresolved > 0 { parts.append("\(unresolved) to confirm or drop") }
        return ReleaseReview(intake: i, drift: drift, summary: parts.joined(separator: " · "), canRelease: unresolved == 0)
    }

    // MARK: - Release

    func release(_ id: UUID) async {
        guard let i = intake(id), i.state == .review, i.changeSet != nil else { return }
        await withTaskHandle(id) { await $0.runRelease(id) }
    }

    private func runRelease(_ id: UUID) async {
        guard var i = intake(id), let cs = i.changeSet else { return }
        let current: GraphSnapshot
        do { current = try await graphReader.read(project: i.projectPath) }
        catch { return fail(id, keepState: true, "Could not read the bead graph before release: \(error)") }
        guard let triaged = triageGraph(id), case .success(let v) = ChangeSetValidator.validate(cs, against: triaged) else {
            return fail(id, keepState: true, "The triage-time graph for this change set is missing or no longer validates; retry triage.")
        }
        let drift = DriftClassifier.classify(v, current: current)
        guard Self.review(i, drift: drift).canRelease else {
            return fail(id, keepState: true, "Drift changed since review; confirm or drop the drifted ops again.")
        }

        // Confirming drift accepts the bead as it is NOW, so the op's `pre` is refreshed to
        // the live state — otherwise BeadWriter's own recheck would refuse the very write the
        // human just confirmed. An edit that became in-progress gains the delivery rating
        // triage never had to give it.
        var ops = cs.ops
        for (n, d) in drift.enumerated() where i.confirmedDrift.contains(n) {
            guard case .drifted(let reason, let suggested) = d, let target = ops[n].existingTarget,
                  let live = current.beads[target]?.precondition else { continue }
            ops[n] = Self.refreshing(ops[n], to: live, rating: i.ratingOverrides[n] ?? suggested, reason: reason)
        }

        // Re-validate against the CURRENT graph, over only the ops that will be written.
        // `unknownBead` means a target vanished after review: drop that op like any other
        // impossible one rather than failing the whole release.
        var skip = i.droppedOps.union(drift.indices.filter { if case .impossible = drift[$0] { true } else { false } })
        var validated: ValidatedChangeSet?, kept: [Int] = []
        for _ in 0...ops.count {
            let (sub, map) = Self.releasable(ops, skipping: skip)
            switch ChangeSetValidator.validate(ChangeSet(graphObservedAt: cs.graphObservedAt, ops: sub), against: current) {
            case .success(let good):
                validated = good; kept = map
            case .failure(let errs):
                let gone = Set(errs.errors.compactMap { if case .unknownBead(let b) = $0 { b } else { nil } })
                let other = errs.errors.filter { if case .unknownBead = $0 { false } else { true } }
                guard other.isEmpty, !gone.isEmpty else {
                    return fail(id, keepState: true, "The change set no longer validates against the live graph: "
                                + errs.errors.map(\.message).joined(separator: "; "))
                }
                skip.formUnion(ops.indices.filter { n in Self.references(ops[n]).contains { gone.contains($0) } })
                continue
            }
            break
        }
        guard let validated else { return fail(id, keepState: true, "The change set could not be reconciled with the live graph.") }

        i.state = .releasing
        i.failure = nil
        save(i)

        let actor = "flightdeck-intake:\(id.uuidString)"
        let outcome = await BeadWriter(runner: processRunner, brPath: brPath, actor: actor)
            .apply(ApplyPlanner.plan(validated, skipping: []), project: i.projectPath)

        var warnings: [String] = []
        if outcome.error == nil {
            var ratings: [Int: DeliveryRating] = [:]
            for (sub, original) in kept.enumerated() { ratings[sub] = i.ratingOverrides[original] }
            let project = i.projectPath
            let actions = DeliveryPlanner.plan(validated.changeSet, ratings: ratings,
                                               hasSession: { [hasSession] in hasSession(project, $0) })
            let delivery = IntakeDelivery(runner: processRunner, amPath: amPath, brPath: brPath, store: store,
                                          inject: { [inject] agent, text, token in inject(project, agent, text, token) })
            warnings = await delivery.deliver(actions, project: project, intakeID: id)
        } else {
            // Notices describe edits as done; after a stop partway, some of them weren't.
            warnings = ["Notices were not sent because the release stopped partway."]
        }

        guard var done = intake(id) else { return }
        done.release = ReleaseRecord(releasedAt: now(), appliedSteps: outcome.applied, idMap: outcome.idMap,
                                     error: outcome.error, warnings: warnings)
        done.state = outcome.error == nil ? .released : .partiallyReleased
        save(done)
    }

    /// `op` with its precondition replaced by the live one, plus a delivery rating when it is
    /// an edit to a bead that is now in progress and triage gave none.
    private static func refreshing(_ op: ChangeOp, to live: Precondition, rating: DeliveryRating?, reason: String) -> ChangeOp {
        switch op {
        case .editBead(let id, let set, _, let delivery):
            var d = delivery
            if d == nil, live.status == "in_progress" { d = Delivery(rating: rating ?? .scopeChange, reason: reason) }
            return .editBead(id: id, set: set, pre: live, delivery: d)
        case .reopen(let id, let r, _): return .reopen(id: id, reason: r, pre: live)
        case .followUp(let t, let of, let title, let d, _): return .followUp(tempId: t, of: of, title: title, description: d, pre: live)
        default: return op
        }
    }

    /// The ops that will actually be written, and each one's index in the original change
    /// set. Mirrors `ApplyPlanner.plan(_:skipping:)`: skipping a create also drops the edges
    /// that point at its tempId, or validation would reject them as dangling.
    static func releasable(_ ops: [ChangeOp], skipping: Set<Int>) -> ([ChangeOp], [Int]) {
        var goneTemps = Set<String>()
        for n in skipping where n < ops.count {
            switch ops[n] {
            case .createBead(let b): goneTemps.insert(b.tempId)
            case .followUp(let t, _, _, _, _): goneTemps.insert(t)
            default: break
            }
        }
        var out: [ChangeOp] = [], map: [Int] = []
        for (n, op) in ops.enumerated() where !skipping.contains(n) {
            if case .addEdge(let from, let to, _) = op,
               [from, to].contains(where: { if case .new(let t) = $0 { goneTemps.contains(t) } else { false } }) { continue }
            out.append(op); map.append(n)
        }
        return (out, map)
    }

    private static func references(_ op: ChangeOp) -> [String] {
        switch op {
        case .createBead: []
        case .addEdge(let from, let to, _):
            [from, to].compactMap { if case .existing(let id) = $0 { id } else { nil } }
        case .editBead(let id, _, _, _), .reopen(let id, _, _): [id]
        case .followUp(_, let of, _, _, _): [of]
        }
    }

    // MARK: - Triage

    enum Turn {
        case initial
        case answers(questions: [String], answers: [String])
        case encodeNow
    }

    private func runTriage(_ id: UUID, turn: Turn) async {
        guard var i = intake(id) else { return }
        i.state = .triaging
        i.failure = nil; i.rawFailureOutput = nil
        save(i)

        let settings: TriageSettings
        if let s = triageSettings { settings = s } else {
            settings = await Task.detached { TriageSettings.detect() }.value
            triageSettings = settings
        }

        // Every turn re-reads the graph, so the change set is validated against — and stamped
        // with — the graph as it was when the agent was working, not at capture time.
        let observedAt = now()
        let graph: GraphSnapshot
        do { graph = try await graphReader.read(project: i.projectPath) }
        catch { return fail(id, "Could not read the bead graph: \(error)") }
        guard !Task.isCancelled else { return }
        let files: TriageFiles
        do { files = try await writeInputs(id, graph: graph, project: i.projectPath) }
        catch { return fail(id, "Could not write triage inputs: \(error)") }
        guard !Task.isCancelled else { return }

        let project = URL(fileURLWithPath: i.projectPath)
        let resume = i.triage?.sessionID
        let prompt: String
        switch turn {
        case .initial:
            prompt = initialPrompt(i, files: files, observedAt: observedAt)
        case .answers(let q, let a):
            prompt = Triage.answersPrompt(questions: q, answers: a)
        case .encodeNow:
            let encode = Triage.encodeNowPrompt(observedAt: observedAt)
            prompt = resume == nil ? initialPrompt(i, files: files, observedAt: observedAt) + "\n\n" + encode : encode
        }
        // A resume is pinned to the session's recorded harness/model/effort, never to the
        // current defaults — a turn must not silently switch models mid-conversation.
        let session = i.triage.map { TriageSettings(harness: $0.harness, model: $0.model, effort: $0.effort) } ?? settings

        var reply = await turnResult(prompt: prompt, resume: resume, settings: session, files: files, project: project)
        guard !Task.isCancelled else { return }
        guard case .success(var result) = reply else {
            if case .failure(let f) = reply { fail(id, f.message, raw: f.raw) }
            return
        }
        i = intake(id) ?? i
        i.triage = HarnessSession(harness: session.harness, sessionID: result.sessionID, model: session.model, effort: session.effort)

        if case .recommendation(let preset, let reason, var cs?) = result.triage {
            cs.graphObservedAt = observedAt  // FD owns this timestamp — see `Triage.initialPrompt`.
            if case .failure(let errs) = ChangeSetValidator.validate(cs, against: graph) {
                // One automatic retry in the same session, errors listed (spec §11).
                save(i)
                reply = await turnResult(prompt: Triage.correctionPrompt(errors: errs.errors, observedAt: observedAt),
                                         resume: result.sessionID, settings: session, files: files, project: project)
                guard !Task.isCancelled else { return }
                switch reply {
                case .failure(let f): return fail(id, f.message, raw: f.raw)
                case .success(let second):
                    result = second
                    guard case .recommendation(let p2, let r2, var cs2?) = second.triage else {
                        return fail(id, "The corrected reply carried no change set.", raw: second.raw)
                    }
                    cs2.graphObservedAt = observedAt
                    if case .failure(let errs2) = ChangeSetValidator.validate(cs2, against: graph) {
                        return fail(id, "The change set failed validation twice: "
                                    + errs2.errors.map(\.message).joined(separator: "; "), raw: second.raw)
                    }
                    result.triage = .recommendation(preset: p2, reason: r2, changeSet: cs2)
                }
            } else {
                result.triage = .recommendation(preset: preset, reason: reason, changeSet: cs)
            }
        }

        switch result.triage {
        case .questions(let q):
            i.exchanges.append(TriageExchange(questions: q))
            i.state = .needsAnswers
        case .recommendation(let preset, let reason, let cs):
            if case .encodeNow = turn, cs == nil {
                return fail(id, "Asked to encode at Bead fidelity, but the reply carried no change set.", raw: result.raw)
            }
            if case .encodeNow = turn {} else {
                i.recommended = preset
                i.recommendationReason = reason
            }
            if let cs { i.changeSet = cs }
            // Bead with its change set already in hand has nothing left to choose.
            i.state = (preset == .bead && cs != nil) ? .review : .awaitingChoice
        }
        save(i)
    }

    private struct TurnReply {
        var sessionID: String
        var triage: TriageResult
        var raw: String
    }
    private struct TurnFailure: Error {
        var message: String
        var raw: String?
    }

    /// One harness invocation, parsed and decoded — every way it can go wrong folded into a
    /// message plus the raw output, which is what `.failed` shows (spec §11).
    private func turnResult(prompt: String, resume: String?, settings: TriageSettings,
                            files: TriageFiles, project: URL) async -> Result<TurnReply, TurnFailure> {
        let request = HarnessRequest(
            harness: settings.harness, model: settings.model, effort: settings.effort, cwd: project,
            readableDirs: [files.directory], prompt: prompt, schemaFile: files.schema,
            schemaJSON: Triage.schemaJSON, resumeSessionID: resume)
        let out: (stdout: Data, stderr: String, exitCode: Int32)
        do { out = try await headless.run(HarnessCommand.build(request), cwd: project) }
        catch { return .failure(TurnFailure(message: "Could not run \(settings.harness.rawValue): \(error)", raw: nil)) }
        let stdout = String(decoding: out.stdout, as: UTF8.self)
        let raw = stdout.isEmpty ? out.stderr : stdout
        guard out.exitCode == 0 else {
            let why = out.stderr.firstLine.isEmpty ? stdout.firstLine : out.stderr.firstLine
            return .failure(TurnFailure(message: "\(settings.harness.rawValue) exited \(out.exitCode): \(why)", raw: raw))
        }
        do {
            let (session, structured) = try HarnessOutput.parse(settings.harness, stdout: out.stdout)
            return .success(TurnReply(sessionID: session, triage: try Triage.decode(structured), raw: raw))
        } catch {
            return .failure(TurnFailure(message: "Triage did not return the expected JSON: \(error)", raw: raw))
        }
    }

    private struct TriageFiles {
        var directory: URL, graph: URL, bv: URL, schema: URL
    }

    private func triageDirectory(_ id: UUID) -> URL {
        store.directory(for: id).appendingPathComponent("triage", isDirectory: true)
    }

    private func writeInputs(_ id: UUID, graph: GraphSnapshot, project: String) async throws -> TriageFiles {
        let dir = triageDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = TriageFiles(directory: dir, graph: dir.appendingPathComponent("graph.json"),
                                bv: dir.appendingPathComponent("bv.json"), schema: dir.appendingPathComponent("schema.json"))
        try IntakeJSON.encoder.encode(graph).write(to: files.graph, options: .atomic)
        // bv is advisory context: a project without it (or a bv that errors) still triages.
        let bv = try? await processRunner.run(bvPath, ["--robot-triage"], cwd: project)
        let bvText = (bv?.exitCode == 0 && !(bv?.stdout.isEmpty ?? true)) ? bv!.stdout : "{}"
        try Data(bvText.utf8).write(to: files.bv, options: .atomic)
        try Data(Triage.schemaJSON.utf8).write(to: files.schema, options: .atomic)
        return files
    }

    /// The graph the current change set was validated against at triage — the baseline
    /// drift is measured from, since `pre` was copied out of it.
    private func triageGraph(_ id: UUID) -> GraphSnapshot? {
        (try? Data(contentsOf: triageDirectory(id).appendingPathComponent("graph.json")))
            .flatMap { try? IntakeJSON.decoder.decode(GraphSnapshot.self, from: $0) }
    }

    private func initialPrompt(_ i: Intake, files: TriageFiles, observedAt: Date) -> String {
        let readme = (i.projectPath as NSString).appendingPathComponent("README.md")
        return Triage.initialPrompt(
            intent: i.intent, graphFile: files.graph.path, triageFile: files.bv.path,
            agentsFile: (i.projectPath as NSString).appendingPathComponent("AGENTS.md"),
            readmeFile: FileManager.default.fileExists(atPath: readme) ? readme : nil,
            observedAt: observedAt)
    }

    // MARK: - Plumbing

    private var graphReader: IntakeGraphReader { IntakeGraphReader(runner: processRunner, brPath: brPath) }

    private func intake(_ id: UUID) -> Intake? { intakes.first { $0.id == id } }

    /// A finished task stays in `tasks` until replaced — cancelling it is a no-op, and
    /// clearing it from inside its own body would race a newer task that already took the slot.
    private func start(_ id: UUID, _ body: @escaping (IntakeService) async -> Void) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await body(self)
        }
    }

    /// `start` for a caller that awaits the work (release): same one-task-per-intake rule.
    private func withTaskHandle(_ id: UUID, _ body: @escaping (IntakeService) async -> Void) async {
        start(id, body)
        await tasks[id]?.value
    }

    private func mutate(_ id: UUID, _ change: (inout Intake) -> Void) {
        guard var i = intake(id) else { return }
        change(&i)
        save(i)
    }

    /// `keepState` leaves a `.review` intake in review (with the reason in `failure`) — a
    /// release refused before anything was written has lost nothing worth re-triaging.
    private func fail(_ id: UUID, keepState: Bool = false, _ message: String, raw: String? = nil) {
        guard var i = intake(id) else { return }
        if !keepState { i.state = .failed }
        i.failure = message
        i.rawFailureOutput = raw
        save(i)
    }

    /// Disk first, then publish: a published state that never reached disk would be lost on
    /// the next launch without anyone having seen it fail.
    private func save(_ intake: Intake) {
        try? store.save(intake)
        if let n = intakes.firstIndex(where: { $0.id == intake.id }) {
            intakes[n] = intake
        } else {
            intakes.insert(intake, at: 0)
        }
    }
}
