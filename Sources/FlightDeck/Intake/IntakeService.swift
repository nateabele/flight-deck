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
        installed("codex", path: path) ? codexDefault : claudeDefault
    }

    /// The models planning rounds may seat, from the same PATH probe as `detect`: codex and
    /// claude defaults for whichever is installed. Neither found falls back to claude alone,
    /// exactly as `detect` does — `PresetExpansion` needs at least one model, and a round that
    /// then fails to find `claude` says so in its own diagnosis rather than never starting.
    static func available(path: String? = LoginShellPath.repairing()["PATH"]) -> AvailableModels {
        let codex = installed("codex", path: path), claude = installed("claude", path: path)
        return AvailableModels(codex: codex ? AvailableModels.defaults.codex : nil,
                               claude: claude || !codex ? AvailableModels.defaults.claude : nil)
    }

    private static func installed(_ tool: String, path: String?) -> Bool {
        (path ?? "").split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
    }
}

/// The part of `IntakeRunnerController` the service drives — a seam so the service's tests
/// never spawn `fd-abduco`.
@MainActor
protocol IntakeRunnerControlling: AnyObject {
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError>
    /// `tape` is the caller's own fresh read of `tape.json`, when it has one — so a tick that
    /// already decoded it doesn't make the controller decode it again. nil reads it from disk.
    func isRunning(_ id: UUID, tape: Tape?) -> Bool
    func reap(_ id: UUID)
    /// Where the runner's `fd-abduco` socket lives, so launch can find a daemon left behind
    /// by an intake that has since stopped shaping.
    func socketPath(for id: UUID) -> String
}

extension IntakeRunnerController: IntakeRunnerControlling {}

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
    /// The bead's state NOW, for every `.drifted` op, keyed by op index. Confirming drift
    /// releases against this, not the triage-time `pre` (`IntakeService.refreshing`), so
    /// the sheet has to show it too — an edit to a bead that was open at triage and is
    /// in progress now gets a holder and a delivery, and gating the rating picker on the
    /// stale `pre` would hide exactly the notice release is about to send.
    var livePre: [Int: Precondition] = [:]

    /// What release will treat as op `i`'s precondition: the live state for a drifted op,
    /// the triage-time `pre` otherwise.
    func effectivePre(_ i: Int) -> Precondition? {
        if let live = livePre[i] { return live }
        guard let ops = intake.changeSet?.ops, i < ops.count else { return nil }
        return switch ops[i] {
        case .editBead(_, _, let p, _), .reopen(_, _, let p), .followUp(_, _, _, _, let p): p
        default: nil
        }
    }
}

/// Orchestrates intakes end to end (spec §4): capture → headless triage (with clarifying
/// Q&A) → recommendation/choice → release review → release (write to `br`, then deliver
/// notices). Every state change is persisted through `save(_:)` before it is published, so a
/// quit at any point leaves `intake.json` describing what actually happened.
@MainActor
final class IntakeService: ObservableObject {
    @Published private(set) var intakes: [Intake]
    /// Each `.shaping` intake's `tape.json` as last read — what `ShapingView` draws and what
    /// `attentionCount` consults. Refreshed on the shared clock (`pollTapes`).
    @Published private(set) var tapes: [UUID: Tape] = [:]
    /// The newest read of each tape, heartbeat and all — what the runner-liveness checks use.
    /// Kept apart from `tapes` because a running tape's heartbeat changes every second, and
    /// republishing for that alone re-rendered every view observing this service each second
    /// of a run for nothing it draws.
    private var latestTapes: [UUID: Tape] = [:]

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
    /// Filled off the main actor by a detached probe started in `init` (the login-shell PATH
    /// lookup behind it can take seconds on first use); nil until that lands.
    private var availableModelsCache: AvailableModels?
    /// nil in a host that cannot run planning rounds; `beginShaping` then fails the intake
    /// with that reason instead of leaving it shaping with nothing behind it.
    private let runner: IntakeRunnerControlling?
    /// `tape.json`'s modification date at the last read, per intake, so an idle tick costs one
    /// stat per shaping intake rather than a decode.
    private var tapeDates: [UUID: Date] = [:]
    /// Runners whose daemon should be collected once it stops counting as running. `reap` is a
    /// no-op while `isRunning` holds (fresh heartbeat, or the spawn grace), which is exactly
    /// the state a runner is in the moment it reaches review or is told to stop — reaping once
    /// right then leaked the `fd-abduco` daemon forever. Every tick retries these instead.
    private var pendingReaps: Set<UUID> = []
    /// The deferred launch recovery, so tests (and nothing else) can await it.
    private(set) var launchRecovery: Task<Void, Never>?

    /// At most one live triage/release per intake. Starting another cancels the first, so a
    /// retry or discard never races a turn whose result would overwrite the newer state. The
    /// token lets a finishing task clear only its OWN entry, never a newer one's; an entry
    /// here therefore means "still running", which is what `release` checks.
    private var tasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    init(
        store: IntakeStore,
        headless: HeadlessRunner = SystemHeadlessRunner(),
        processRunner: FlywheelProcessRunner = SystemFlywheelProcessRunner(),
        brPath: String = "br", bvPath: String = "bv", amPath: String = "am",
        triageSettings: TriageSettings? = nil,
        availableModels: AvailableModels? = nil,
        clock: WatchClock? = nil,
        runner: IntakeRunnerControlling? = nil,
        inject: @escaping (String, String, String, UUID) -> Bool,
        hasSession: @escaping (String, String) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.headless = headless
        self.processRunner = processRunner
        self.brPath = brPath; self.bvPath = bvPath; self.amPath = amPath
        self.triageSettings = triageSettings
        self.availableModelsCache = availableModels
        self.runner = runner
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

        // `.shaping` is deliberately NOT interrupted: its runner is detached and may still be
        // working, and even a dead one left everything it needs in `tape.json`. The first
        // `pollTapes` brings back a runner for any tape with unfinished work (see
        // `resumeIfStalled`), and collects daemons whose intake stopped shaping while FD was
        // gone. Deferred to its own main-actor turn: this service is built lazily, often from
        // inside a view body, and publishing `tapes`/`intakes` or spawning a process there is
        // a SwiftUI "publishing changes from within view updates" fault.
        launchRecovery = Task { @MainActor [weak self] in
            guard let self else { return }
            if let runner = self.runner {
                for i in self.intakes where i.state != .shaping
                    && FileManager.default.fileExists(atPath: runner.socketPath(for: i.id)) {
                    self.pendingReaps.insert(i.id)
                }
            }
            self.pollTapes()
        }
        clock?.add(self) { [weak self] in self?.pollTapes() }

        // Warm the model probe off the main actor so Start never waits on a login shell.
        if availableModelsCache == nil {
            Task.detached { [weak self] in
                let detected = TriageSettings.available()
                await MainActor.run { [weak self] in
                    if self?.availableModelsCache == nil { self?.availableModelsCache = detected }
                }
            }
        }
    }

    // MARK: - Reads

    /// The one spelling of a project path this service stores and compares — exactly how
    /// `SessionStore` keys flywheel identities (`flywheelStandardizedKey`,
    /// `bootFlywheelIdentityIfNeeded`). Without it `/p/` and `/p` are two projects, and a
    /// holder's session keyed by the standardized path is never found, so an invalidating
    /// change silently degrades to mail-only.
    static func projectKey(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// Newest first; discarded intakes are kept on disk but never listed.
    func intakes(forProject path: String) -> [Intake] {
        let key = Self.projectKey(path)
        return intakes.filter { Self.projectKey($0.projectPath) == key && $0.state != .discarded }
    }

    func attentionCount(forProject path: String) -> Int {
        intakes(forProject: path).filter { $0.state.needsAttention || shapingNeedsAttention($0) }.count
    }

    /// A shaping intake whose runner has stopped and is waiting for the human. `.idle` counts
    /// only with no target: an idle tape WITH one is queued work a runner is about to pick up
    /// (the same "unfinished work" test launch recovery uses), and lighting the badge for the
    /// second between Start and the runner's first write would be noise. No tape read yet
    /// likewise reads as starting, not waiting. Nor does a tape with commands the runner hasn't
    /// acked: a ▶ just pressed on a paused tape is queued work, not a tape waiting for the human.
    private func shapingNeedsAttention(_ i: Intake) -> Bool {
        guard i.state == .shaping, let tape = tapes[i.id] else { return false }
        let waiting: Bool
        switch tape.status {
        case .paused, .failed, .stopped: waiting = true
        case .idle: waiting = tape.target == .none
        case .running, .reachedReview: waiting = false
        }
        // Checked last, so the common case (not waiting) never touches `commands.jsonl`.
        return waiting && !hasPendingCommands(i.id, tape)
    }

    /// Commands queued after the last one the runner acked — work a runner still has to read.
    private func hasPendingCommands(_ id: UUID, _ tape: Tape) -> Bool {
        !tapeStore(id).commands(after: tape.ackedCommandSeq).isEmpty
    }

    /// The live task for `id`, if any — so tests (and nothing else) can await a turn.
    func task(for id: UUID) -> Task<Void, Never>? { tasks[id]?.task }

    // MARK: - Pipeline

    func capture(intent: String, project: String) {
        guard !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let intake = Intake(projectPath: Self.projectKey(project), intent: intent, createdAt: now())
        save(intake)
        start(intake.id) { await $0.runTriage(intake.id, turn: .initial) }
    }

    func answer(_ id: UUID, answers: [String]) {
        guard var i = intake(id), i.state == .needsAnswers, !i.exchanges.isEmpty else { return }
        i.exchanges[i.exchanges.count - 1].answers = answers
        save(i)
        clearAnswerDrafts(id)
        let questions = i.exchanges[i.exchanges.count - 1].questions
        start(id) { await $0.runTriage(id, turn: .answers(questions: questions, answers: answers)) }
    }

    // MARK: - Answer drafts

    /// What `answer-drafts.json` holds: the unsent answers, and the exact questions they were
    /// typed against — so a follow-up round with the same number of questions can never pick
    /// up drafts written for different ones.
    private struct AnswerDrafts: Codable {
        var questions: [String]
        var answers: [String]
    }

    private func answerDraftsURL(_ id: UUID) -> URL {
        store.directory(for: id).appendingPathComponent("answer-drafts.json")
    }

    /// Persists the open round's unsent answers. `intake.json` already survives a relaunch in
    /// every state; the drafts were `@State` alone, so a release swap mid-answer threw away
    /// whatever had been typed. Refused unless `questions` is still the open round: a debounced
    /// write landing after Send would otherwise resurrect drafts for a round already answered.
    func saveAnswerDrafts(_ id: UUID, questions: [String], answers: [String]) {
        guard let i = intake(id), i.state == .needsAnswers, let open = i.exchanges.last,
              open.answers == nil, open.questions == questions, answers.count == questions.count
        else { return }
        guard let data = try? JSONEncoder().encode(AnswerDrafts(questions: questions, answers: answers)) else { return }
        try? data.write(to: answerDraftsURL(id), options: .atomic)
    }

    /// The drafts saved against exactly `questions`, or nil. Drafts for any other question set
    /// are stale — a newer round replaced them — so they're deleted rather than left to match
    /// by accident later.
    func answerDrafts(_ id: UUID, questions: [String]) -> [String]? {
        guard let data = try? Data(contentsOf: answerDraftsURL(id)),
              let drafts = try? JSONDecoder().decode(AnswerDrafts.self, from: data) else { return nil }
        guard drafts.questions == questions, drafts.answers.count == questions.count else {
            clearAnswerDrafts(id)
            return nil
        }
        return drafts.answers
    }

    private func clearAnswerDrafts(_ id: UUID) {
        try? FileManager.default.removeItem(at: answerDraftsURL(id))
    }

    /// Bead encodes (or goes straight to review); anything else starts planning rounds with the
    /// preset's stock config. The UI starts an edited config through `beginShaping` directly,
    /// and once that has run the intake is `.shaping`, so this can't overwrite it. `.parked`
    /// intakes — chosen before the round engine existed — resume through here too.
    func choose(_ id: UUID, preset: Preset) {
        guard var i = intake(id), [.awaitingChoice, .review, .parked].contains(i.state) else { return }
        guard preset == .bead else {
            // From `.review` only Bead (re-review the change set in hand) is meaningful: a
            // review already holds a finished change set, and shaping over it would silently
            // replace what the human is reviewing. Rejected here rather than left to fall
            // through `beginShaping`'s own state guard, so the rule is stated where it applies.
            guard i.state != .review else { return }
            guard let config = PresetExpansion.config(for: preset, available: availableModels()) else {
                return fail(id, "No model is available to run planning rounds.")
            }
            return beginShaping(id, preset: preset, config: config)
        }
        if i.changeSet != nil {
            i.state = .review
            save(i)
        } else {
            start(id) { await $0.runTriage(id, turn: .encodeNow) }
        }
    }

    // MARK: - Shaping

    /// Starts planning rounds: records the preset and (possibly edited) config, queues the
    /// config's default play as the first command, then makes sure a runner is there to read
    /// it. Saved before the command is queued, so a runner that starts reading the moment it
    /// is spawned always finds the intake it belongs to already `.shaping`.
    func beginShaping(_ id: UUID, preset: Preset, config: RoundConfig) {
        guard var i = intake(id), i.state == .awaitingChoice || i.state == .parked else { return }
        i.chosenPreset = preset
        i.roundConfig = config
        i.state = .shaping
        i.failure = nil; i.rawFailureOutput = nil
        save(i)
        let play: TapeCommand = switch config.defaultPlay {
        case .toReview: .toReview
        case .nextMajor: .nextMajor
        case .step: .step
        }
        do { _ = try tapeStore(id).appendCommand(play) }
        catch { return fail(id, "Could not queue the first planning round: \(error)") }
        startRunner(id)
    }

    /// Queues `command` for the runner, then relaunches it for anything that asks for more
    /// rounds — a runner that paused, stopped or reached a target has exited, so "play" means
    /// a new one.
    ///
    /// `.stop` with no live runner also starts one, to CONSUME it: left queued, the stop sat
    /// unread until the next play spawned a runner, which then read the stop first and exited
    /// — the play the human just pressed did nothing. The runner applies it, writes `.stopped`
    /// and exits. `.pause` needs no such care (a later play overrides it, since commands
    /// apply in order), and an annotation is consumed by whichever round runs next.
    func send(_ id: UUID, _ command: TapeCommand) {
        guard intake(id)?.state == .shaping else { return }
        do { _ = try tapeStore(id).appendCommand(command) }
        catch { return fail(id, "Could not queue the command for the planning runner: \(error)") }
        switch command {
        case .pause, .annotate: return
        case .stop: if runner?.isRunning(id, tape: nil) != true { startRunner(id) }
        case .step, .nextMajor, .toReview, .extend: startRunner(id)
        }
    }

    /// Which models planning rounds can seat: the PATH probe triage uses, run off the main
    /// actor by `init`. Until that lands, the stock both-harness defaults — never a blocking
    /// login-shell lookup on the main actor. A default naming a harness this machine lacks
    /// is not silent: its round fails and falls back or pauses with a diagnosis.
    func availableModels() -> AvailableModels {
        availableModelsCache ?? .defaults
    }

    /// A file a round wrote into `checkpoints/<checkpoint>/` — `ShapingView`'s `loadFile`.
    /// A synchronous read on the main actor: fine at plan sizes (a plan, a change set, a
    /// graph — kilobytes), and `ShapingView` only calls it when its viewer key changes.
    func checkpointFile(_ id: UUID, checkpoint: Int, _ path: String) -> Data? {
        try? Data(contentsOf: tapeStore(id).checkpointDirectory(checkpoint).appendingPathComponent(path))
    }

    /// One clock beat: re-read the tape of every `.shaping` intake whose `tape.json` changed
    /// since the last read (one stat each when nothing did), publish it, move a tape that
    /// reached review into release review, bring back a runner that died mid-work, and collect
    /// any daemon queued in `pendingReaps` that has stopped running. Also run once by launch
    /// recovery, which is what makes a relaunch resume.
    func pollTapes() {
        let shaping = Set(intakes.lazy.filter { $0.state == .shaping }.map(\.id))
        for gone in Set(latestTapes.keys).union(tapes.keys).union(tapeDates.keys).subtracting(shaping) {
            tapes[gone] = nil
            latestTapes[gone] = nil
            tapeDates[gone] = nil
        }
        for id in shaping {
            let store = tapeStore(id)
            let modified = (try? FileManager.default.attributesOfItem(atPath: store.tapeURL.path))?[.modificationDate] as? Date
            if latestTapes[id] == nil || modified != tapeDates[id] {
                tapeDates[id] = modified
                let tape = store.loadTape()
                latestTapes[id] = tape
                if tapes[id].map({ !Self.sameIgnoringLiveness($0, tape) }) ?? true { tapes[id] = tape }
            }
            if latestTapes[id]?.status == .reachedReview { finishShaping(id) } else { resumeIfStalled(id) }
        }
        if let runner {
            for id in pendingReaps where !runner.isRunning(id, tape: nil) {
                runner.reap(id)
                pendingReaps.remove(id)
            }
        }
    }

    /// Equal but for the runner's liveness fields, which change every poll of a running tape
    /// and which no view draws — see `latestTapes`.
    private static func sameIgnoringLiveness(_ a: Tape, _ b: Tape) -> Bool {
        var a = a, b = b
        a.heartbeat = nil; b.heartbeat = nil
        a.runnerPID = nil; b.runnerPID = nil
        return a == b
    }

    /// A tape with unfinished work — `.running`, `.idle` with a target, or commands queued that
    /// no runner has acked — and no live runner behind it: the runner crashed or was killed,
    /// at launch or mid-session, or a spawn was deferred (`RunnerStartError.notReady`). A
    /// paused, stopped or failed tape with nothing queued stopped for a reason the human has
    /// to see, and respawning it would just stop again. `isRunning` is the controller's own
    /// heartbeat/grace judgement, so a just-spawned runner that hasn't written yet is never
    /// spawned twice.
    private func resumeIfStalled(_ id: UUID) {
        guard let runner, let tape = latestTapes[id],
              tape.status == .running || (tape.status == .idle && tape.target != .none) || hasPendingCommands(id, tape),
              !runner.isRunning(id, tape: tape) else { return }
        startRunner(id)
    }

    /// The runner reached review: its final change set is whatever the LATEST checkpoint that
    /// carries one says (a freshEyes/dedup round may have come after polish, or a plan-only
    /// round after both). Its `graph.json` — the snapshot encode validated against, carried
    /// forward by every round since — replaces triage's, because release review measures drift
    /// from and re-validates against `triageGraph`; the triage-time graph predates beads the
    /// shaped change set may reference, and would make the review sheet fail to load.
    private func finishShaping(_ id: UUID) {
        guard var i = intake(id), i.state == .shaping, let tape = latestTapes[id] else { return }
        let store = tapeStore(id)
        var found: (changeSet: ChangeSet, graph: Data)?
        for cp in tape.checkpoints.reversed() {
            let dir = store.checkpointDirectory(cp.id)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("changeset.json")) else { continue }
            guard let cs = try? ChangeSet.decode(data),
                  let graph = try? Data(contentsOf: dir.appendingPathComponent("graph.json")) else { break }
            found = (cs, graph)
            break
        }
        pendingReaps.insert(id)
        // Never an empty review: with nothing to release, "review" would be a dead end that
        // looks like success.
        guard let found else {
            return fail(id, "Planning rounds reached review, but no checkpoint has a readable change set and graph to release.")
        }
        do {
            try FileManager.default.createDirectory(at: triageDirectory(id), withIntermediateDirectories: true)
            try found.graph.write(to: triageDirectory(id).appendingPathComponent("graph.json"), options: .atomic)
        } catch {
            return fail(id, "Could not record the planning rounds' graph for release review: \(error)")
        }
        i.changeSet = found.changeSet
        i.ratingOverrides = [:]; i.droppedOps = []; i.confirmedDrift = []
        i.failure = nil
        i.state = .review
        save(i)
    }

    /// `ensureRunning`, with a refusal failing the intake so it shows why nothing is running.
    private func startRunner(_ id: UUID) {
        guard let runner else { return fail(id, "This build cannot run planning rounds (no runner).") }
        // The runner is wanted again (a retry); collecting it later would kill that one.
        pendingReaps.remove(id)
        // `.notReady` isn't a refusal: the tick retries it, since the queued command (or the
        // tape's unfinished work) still reads as work to `resumeIfStalled`.
        if case .failure(let error) = runner.ensureRunning(id), error != .notReady {
            fail(id, "Could not start the planning runner: \(Self.describe(error))")
        }
    }

    /// Readable text for a start refusal. `if case` rather than an exhaustive `switch` so a
    /// case added to `RunnerStartError` later still reads sensibly here without an edit.
    static func describe(_ error: RunnerStartError) -> String {
        if case .noBundledCLI = error { return "this build has no bundled flightdeck CLI" }
        if case .noFdAbduco = error { return "this build has no usable fd-abduco" }
        if case .spawnFailed(let why) = error { return why }
        return String(describing: error)
    }

    func retry(_ id: UUID) {
        guard var i = intake(id), i.state == .failed || i.state == .interrupted else { return }
        // A shaping run that failed (a runner that wouldn't start, a review with nothing to
        // release) still has its tape: resume it where it stopped rather than throwing away
        // every round for a fresh triage.
        if i.state == .failed, i.roundConfig != nil, let preset = i.chosenPreset, preset != .bead {
            i.state = .shaping
            i.failure = nil; i.rawFailureOutput = nil
            save(i)
            return startRunner(id)
        }
        // A fresh triage from the unchanged intent: the old session's context is what went
        // wrong (or is gone), and a re-read graph is the only safe base after an interrupted
        // release. The earlier Q&A goes with it — the agent will ask again if it still matters.
        i.recommended = nil; i.recommendationReason = nil; i.triage = nil; i.exchanges = []
        i.changeSet = nil; i.failure = nil; i.rawFailureOutput = nil
        i.ratingOverrides = [:]; i.droppedOps = []; i.confirmedDrift = []
        save(i)
        start(id) { await $0.runTriage(id, turn: .initial) }
    }

    /// Refused (returns false) while `.releasing`: cancelling mid-write would leave beads
    /// half-written with no record of how far it got, and the release's own final save would
    /// then overwrite `.discarded` anyway. The UI disables Discard in that state.
    @discardableResult
    func discard(_ id: UUID) -> Bool {
        guard var i = intake(id), i.state != .releasing else { return false }
        tasks.removeValue(forKey: id)?.task.cancel()
        if i.state == .shaping {
            // Stop first so a live runner exits at its next command check instead of shaping
            // on for an intake nobody can see; the tick collects its daemon once it has.
            _ = try? tapeStore(id).appendCommand(.stop)
            pendingReaps.insert(id)
        }
        i.state = .discarded
        save(i)
        return true
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
        var review = Self.review(latest, drift: drift)
        for (n, d) in drift.enumerated() {
            guard case .drifted = d, let target = cs.ops[n].existingTarget,
                  let live = current.beads[target]?.precondition else { continue }
            review.livePre[n] = live
        }
        return review
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
        // `.releasing` is set here, before the first await, so a second click (or a discard)
        // arriving while the graph is re-read already sees a release in flight.
        guard var i = intake(id), i.state == .review, i.changeSet != nil, tasks[id] == nil else { return }
        i.state = .releasing
        i.failure = nil
        save(i)
        start(id) { await $0.runRelease(id) }
        await tasks[id]?.task.value
    }

    private func runRelease(_ id: UUID) async {
        guard let i = intake(id), let cs = i.changeSet else { return }
        let current: GraphSnapshot
        do { current = try await graphReader.read(project: i.projectPath) }
        catch { return fail(id, backTo: .review, "Could not read the bead graph before release: \(error)") }
        guard let triaged = triageGraph(id), case .success(let v) = ChangeSetValidator.validate(cs, against: triaged) else {
            return fail(id, backTo: .review, "The triage-time graph for this change set is missing or no longer validates; retry triage.")
        }
        let drift = DriftClassifier.classify(v, current: current)
        guard Self.review(i, drift: drift).canRelease else {
            return fail(id, backTo: .review, "Drift changed since review; confirm or drop the drifted ops again.")
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
                    return fail(id, backTo: .review, "The change set no longer validates against the live graph: "
                                + errs.errors.map(\.message).joined(separator: "; "))
                }
                skip.formUnion(ops.indices.filter { n in Self.references(ops[n]).contains { gone.contains($0) } })
                continue
            }
            break
        }
        guard let validated else { return fail(id, backTo: .review, "The change set could not be reconciled with the live graph.") }
        guard !Task.isCancelled else { return }

        let actor = "flightdeck-intake:\(id.uuidString)"
        let steps = ApplyPlanner.plan(validated, skipping: [])
        let outcome = await BeadWriter(runner: processRunner, brPath: brPath, actor: actor)
            .apply(steps, project: i.projectPath)

        // The plan is ordered and BeadWriter stops at the first failure, so exactly
        // `steps[..<applied]` landed. A notice says "this bead changed", so it goes only to
        // holders of edits whose `update` step is in that prefix; the holder of an edit that
        // never landed is named in the warnings instead of being told about a change that
        // didn't happen.
        let landed = Set(steps.prefix(outcome.applied).compactMap { if case .update(let id, _) = $0 { id } else { nil } })
        var ratings: [Int: DeliveryRating] = [:]
        for (sub, original) in kept.enumerated() { ratings[sub] = i.ratingOverrides[original] }
        let project = i.projectPath
        let planned = DeliveryPlanner.plan(validated.changeSet, ratings: ratings,
                                           hasSession: { [hasSession] in hasSession(project, $0) })
        var warnings: [String] = []
        var unnotified = Set<String>()
        for action in planned {
            guard case .mail(let to, let bead, _, _) = action, !landed.contains(bead) else { continue }
            if unnotified.insert(bead).inserted {
                warnings.append("\(bead) (held by \(to)) was not changed because the release stopped partway, so \(to) was not notified.")
            }
        }
        let actions = planned.filter { action in
            switch action {
            case .mail(_, let bead, _, _), .inject(_, let bead, _), .reclaim(let bead, _, _): landed.contains(bead)
            }
        }
        let delivery = IntakeDelivery(runner: processRunner, amPath: amPath, brPath: brPath, store: store,
                                      inject: { [inject] agent, text, token in inject(project, agent, text, token) })
        warnings += await delivery.deliver(actions, project: project, intakeID: id)

        // Deliberately NOT gated on cancellation: beads are already written, and a record of
        // exactly what landed is the one thing a release must never lose. (Nothing cancels a
        // release today — `discard` refuses and every other starter is state-gated.)
        guard var done = intake(id) else { return }
        done.release = ReleaseRecord(releasedAt: now(), appliedSteps: outcome.applied, idMap: outcome.idMap,
                                     error: outcome.error, warnings: warnings)
        done.state = outcome.error == nil ? .released : .partiallyReleased
        save(done)
    }

    /// `op` with its precondition replaced by the live one, plus a delivery rating when it is
    /// an edit to a bead that is now in progress and triage gave none. Also what the review
    /// sheet's footer counts notices from, so its "N notices" matches what release will send.
    static func refreshing(_ op: ChangeOp, to live: Precondition, rating: DeliveryRating?, reason: String) -> ChangeOp {
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
        guard var i = intake(id), !Task.isCancelled else { return }
        i.state = .triaging
        i.failure = nil; i.rawFailureOutput = nil
        save(i)

        let settings: TriageSettings
        if let s = triageSettings { settings = s } else {
            settings = await Task.detached { TriageSettings.detect() }.value
            triageSettings = settings
            guard !Task.isCancelled else { return }
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
                guard !Task.isCancelled else { return }
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
        guard !Task.isCancelled else { return }
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
        func existing(_ name: String) -> String? {
            let path = (i.projectPath as NSString).appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        return Triage.initialPrompt(
            intent: i.intent, graphFile: files.graph.path, triageFile: files.bv.path,
            agentsFile: existing("AGENTS.md"), readmeFile: existing("README.md"), observedAt: observedAt)
    }

    // MARK: - Plumbing

    private func tapeStore(_ id: UUID) -> TapeStore { TapeStore(intakeDirectory: store.directory(for: id)) }

    private var graphReader: IntakeGraphReader { IntakeGraphReader(runner: processRunner, brPath: brPath) }

    private func intake(_ id: UUID) -> Intake? { intakes.first { $0.id == id } }

    private func start(_ id: UUID, _ body: @escaping (IntakeService) async -> Void) {
        tasks[id]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await body(self)
            if self.tasks[id]?.token == token { self.tasks[id] = nil }
        }
        tasks[id] = (token, task)
    }

    private func mutate(_ id: UUID, _ change: (inout Intake) -> Void) {
        guard var i = intake(id) else { return }
        change(&i)
        save(i)
    }

    /// `backTo: .review` is for a release refused before anything was written — it has lost
    /// nothing worth re-triaging. A no-op once the task is cancelled: the canceller (discard,
    /// retry) has already set the state, and a failure here would overwrite it.
    private func fail(_ id: UUID, backTo state: IntakeState = .failed, _ message: String, raw: String? = nil) {
        guard !Task.isCancelled, var i = intake(id) else { return }
        i.state = state
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
