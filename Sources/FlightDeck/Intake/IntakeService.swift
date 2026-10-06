import AppKit
import FleetKit
import IntakeKit
import OSLog

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
    /// Every task the graph holds, id → title, as of this read — so the sheet names the tasks
    /// an edit, reopen, follow-up or dependency touches by title instead of by raw id.
    var titles: [String: String] = [:]

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

/// The optimistic "starting" state a start button leaves behind (spec §3.1, "No dead moments"):
/// set in the same main-actor turn as the click, so the card answers in well under 100 ms even
/// though the process behind it takes seconds to say anything.
struct PendingStart: Equatable {
    let kind: Kind
    let since: Date
    /// Nothing for `IntakeService.queuedAfter` since the click: still expected, but the card
    /// stops saying "starting" and shows a quiet queued row instead of a spinner that lies.
    var queued = false
    enum Kind: Equatable { case triage, round(PlannedRound?) }
}

/// The running round's seat files (`IntakeService.seatActivities`, `runRecords`, `seatResults`),
/// observable apart from the service: the only state that changes every second of a run.
///
/// Published per intake (`channel(_:)`), not as one object: with one, a beat on any shaping
/// intake redrew every reader of every intake — two shaping intakes redrew each other's live
/// cards every second. A write notifies only the channels whose intake's files changed.
@MainActor
final class SeatFeed {
    fileprivate(set) var activities: [UUID: [String: SeatActivity]] = [:] {
        didSet { notify(Self.changed(oldValue, activities)) }
    }
    fileprivate(set) var records: [UUID: [String: RunRecord]] = [:] {
        didSet { settled(Self.changed(oldValue, records)) }
    }
    fileprivate(set) var results: [UUID: [String: SeatResult]] = [:] {
        didSet { settled(Self.changed(oldValue, results)) }
    }
    /// Fired when a seat's `run.json` or `result.json` changes — the rate at which agents start
    /// and finish, never `activities`' once-a-second beat. `SessionStore` hangs the phone's
    /// intake summary refresh here: those files are what move "k of n agents", and they are
    /// deliberately not published through `IntakeService.objectWillChange`, so without this an
    /// agent finishing reached the phone only on an unrelated change or the 60 s tick.
    var onSettled: (() -> Void)?
    /// Kept for the service's lifetime, never dropped: a reader holds its channel, and a
    /// replacement made later would be one it never hears from.
    private var channels: [UUID: SeatChannel] = [:]

    /// What intake `id`'s readers observe.
    func channel(_ id: UUID) -> SeatChannel {
        if let channel = channels[id] { return channel }
        let channel = SeatChannel()
        channels[id] = channel
        return channel
    }

    /// Intake `id`'s seats, as the live card and the seat inspector take them.
    func files(_ id: UUID) -> SeatFiles {
        SeatFiles(activities: activities[id] ?? [:], records: records[id] ?? [:], results: results[id] ?? [:])
    }

    private func notify(_ ids: Set<UUID>) {
        for id in ids { channels[id]?.objectWillChange.send() }
    }

    private func settled(_ ids: Set<UUID>) {
        notify(ids)
        if !ids.isEmpty { onSettled?() }
    }

    private static func changed<V: Equatable>(_ old: [UUID: V], _ new: [UUID: V]) -> Set<UUID> {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }
}

/// One intake's seat-file publishes (`SeatFeed.channel`) — carries no state of its own; readers
/// read the files back from the feed.
@MainActor
final class SeatChannel: ObservableObject {}

/// Orchestrates intakes end to end (spec §4): capture → headless triage (with clarifying
/// Q&A) → recommendation/choice → release review → release (write to `br`, then deliver
/// notices). Every state change is persisted through `save(_:)` before it is published, so a
/// quit at any point leaves `intake.json` describing what actually happened.
@MainActor
final class IntakeService: ObservableObject {
    @Published private(set) var intakes: [Intake]
    /// Which intake each project's Intakes list has selected, keyed by `projectKey`. Lives
    /// here rather than `ProjectView`'s `@State`, because `ProjectView` is keyed by `Repo` —
    /// SwiftUI gives it a fresh identity, and resets its `@State`, on every project switch. A
    /// service already scoped per-project outlives that: it's what made the selection survive
    /// switching to another project and back, which `@State` did not.
    ///
    /// Not on `SessionStore`: it has no map of per-project UI state to fold into (its
    /// per-project reads are all identity/config — `flywheelSuggestion`, `intakeService`
    /// itself — not view state), so there is nothing there this would be joining rather than
    /// duplicating. This service is already the per-project owner for everything else about
    /// an intake, so its selection joins that, not a new home on the store.
    @Published private(set) var selectedIntake: [String: UUID] = [:]
    /// The projects whose detail pane shows its trailing inspector, keyed by `projectKey`. Here
    /// for the reason `selectedIntake` is: as `ProjectView` `@State` it reset on a switch to
    /// another project or tab and back — the notes rail closed itself behind the human.
    @Published private(set) var inspectorProjects: Set<String> = []
    /// The projects whose Intakes list is collapsed to its rail (`IntakeRail`), keyed by
    /// `projectKey`. Here for the reason `inspectorProjects` is: as `ProjectView` `@State` the
    /// list sprang back open on every switch to another project or tab and back.
    @Published private(set) var collapsedListProjects: Set<String> = []
    /// Each `.shaping` intake's `tape.json` as last read, with the clicks the runner hasn't acked
    /// yet folded on top (`overlays`) — what the detail pane draws and what `attentionCount`
    /// consults. Refreshed on the shared clock (`pollTapes`), and by `send` in the click's turn.
    @Published private(set) var tapes: [UUID: Tape] = [:]
    /// The tape-shaping commands `send` queued that no tape read has acked yet, in seq order —
    /// see `TapeOverlay`. Only `tapes` shows them: `latestTapes` stays the runner's word, since
    /// liveness, resumption and announcements are about what it has done, not what was asked.
    private var overlays: [UUID: [CommandEnvelope]] = [:]

    /// `hasPendingCommands`'s memory, per intake. Dropped with the intake's other shaping
    /// state in `pollTapes` when it stops shaping.
    private var pendingCommandsMemo: [UUID: PendingCommandsMemo] = [:]
    private struct PendingCommandsMemo {
        let stamp: TranscriptStamp?
        let acked: Int
        let pending: Bool
    }
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
    private let defaults: UserDefaults
    /// `UserDefaults` key for `selectedIntake`, persisted as `[path: uuidString]` since
    /// `UserDefaults` plists can't hold `UUID` values directly.
    private static let selectionDefaultsKey = "IntakeSelectionByProject"
    /// `UserDefaults` key for `inspectorProjects`, persisted as an array of paths.
    private static let inspectorDefaultsKey = "IntakeInspectorByProject"
    /// `UserDefaults` key for `collapsedListProjects`, persisted as an array of paths.
    private static let collapsedListDefaultsKey = "IntakeListCollapsedByProject"
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
    /// Each triaging intake's live activity, and its file's mtime at the last read — see
    /// `triageActivity(_:)`. Published so a view drawing it redraws when it moves.
    @Published private(set) var triageActivities: [UUID: SeatActivity] = [:]
    private var triageActivityDates: [UUID: Date] = [:]
    /// The running round's seat files, published on their own object (`SeatFeed`). A running
    /// round rewrites them about once a second; published here, every beat redrew every view
    /// observing this service — and, through `SessionStore`'s forward of `objectWillChange`,
    /// every view observing the store — for values only the live card and the seat inspector
    /// draw. Those two observe `seats` alone.
    let seats = SeatFeed()
    /// The round in progress's seats (spec §6), keyed by `runs/` directory name — only while a
    /// tape has `roundInProgress`, so a paused tape's finished runs are never re-read.
    private(set) var seatActivities: [UUID: [String: SeatActivity]] {
        get { seats.activities }
        set { seats.activities = newValue }
    }
    /// The same seats' `run.json` — what says a seat exited even when its activity never got
    /// to write `finished`.
    private(set) var runRecords: [UUID: [String: RunRecord]] {
        get { seats.records }
        set { seats.records = newValue }
    }
    /// The same seats' `result.json` — each seat's outcome from the moment its own output
    /// parsed, well before the round's checkpoint lands (`SeatResult`).
    private(set) var seatResults: [UUID: [String: SeatResult]] {
        get { seats.results }
        set { seats.results = newValue }
    }
    /// Each shaping intake's refine/polish convergence series (spec §8).
    @Published private(set) var convergence: [UUID: [ConvergenceCycle]] = [:]
    /// Each shaping intake's cross-check readings (coverage spec §5.4), folded with `convergence`
    /// from the same files.
    @Published private(set) var coverage: [UUID: [CoverageReading]] = [:]
    /// A start the human asked for that hasn't shown any sign of life yet — see `PendingStart`.
    /// Set by `answer`, `beginShaping` and `send`'s play commands; cleared by `settlePending` on
    /// the first sign of that work, and by `save` the moment the intake leaves the state the
    /// work runs in (a turn that failed before writing anything, a discard).
    @Published private(set) var pending: [UUID: PendingStart] = [:]
    /// The latest pause or stop `send` queued, until the runner acknowledges it — what the
    /// control bar's "Pausing…"/"Stopping…" wait on (`HaltRequest.label`). Kept here rather
    /// than in the view so the Run menu and the bar's buttons share one answer.
    @Published private(set) var halts: [UUID: HaltRequest] = [:]
    /// Plan edits the app could not carry onto a newer head (`EditLayer.retarget`) — the
    /// runner records its own in the tape (`PlanLayers.conflictedEdits`); these are the ones
    /// only the app saw. Behind the live card's conflict banner, with the tape's.
    @Published private(set) var editConflicts: [UUID: [EditConflict]] = [:]
    /// Intakes whose plan has already shown "Your edits are kept…" — once per plan, so it
    /// lives here rather than in the plan section, which is rebuilt on every visit.
    private(set) var editNoteShown: Set<UUID> = []
    /// Each shaping intake's plan-edit router (`PlanEditRouter`): which edits are stuck on
    /// their own round and which were sent but not yet applied. The intake's, not the plan
    /// section's — as the section's `@State` it was lost on every intake switch, and an edit
    /// that had already conflicted was merged onto the head on the next commit.
    private var editRouters: [UUID: PlanEditRouter] = [:]
    /// Each intake's folded plan sections, for the session: a view state, never written to disk.
    private var planFoldStores: [UUID: PlanFoldStore] = [:]
    /// How long a pending start may stay silent before it reads as queued rather than starting.
    static let queuedAfter: TimeInterval = 15
    /// Each seat file's mtime at its last read, per intake, keyed by path — the same stat-first
    /// rule `tapeDates` holds `tape.json` to, per file, so an idle tick decodes nothing.
    private var seatFileDates: [UUID: [String: Date]] = [:]
    /// The round `seatActivities` belongs to; a different one starts the seat maps afresh.
    private var seatRounds: [UUID: PlannedRound] = [:]
    /// What `convergence` was last folded at: the checkpoint count, and the head plan's
    /// `plan.user.md` mtime (a human edit changes the plan the next round's churn is measured
    /// from without adding a checkpoint). The fold reads every refine/polish checkpoint's plan and
    /// proposals, so it runs when one of those moves — never on a heartbeat.
    private var convergenceKeys: [UUID: ConvergenceKey] = [:]
    private struct ConvergenceKey: Equatable { let count: Int; let userEdits: Date? }
    /// The fold in flight per intake, so tests (and nothing else) can await it.
    private var convergenceFolds: [UUID: Task<Void, Never>] = [:]
    private var flapPolicies: [UUID: FlapPolicy] = [:]
    /// Intakes whose policy has been seeded from a tape (see `seedFlapsIfNeeded`).
    private var flapSeeded: Set<UUID> = []
    /// Every file this service polls for live state goes through here — a seam so a test can
    /// count reads and prove a tick that found nothing changed read nothing.
    /// `@Sendable` because the convergence fold reads through it off the main actor.
    private let readFile: @Sendable (URL) -> Data?
    /// Speaks a state change to VoiceOver (spec §14's live regions) — `postAnnouncement` in the
    /// app, a recorder in tests. Called only with `announcement(from:to:)`'s words.
    private let announce: (String) -> Void

    /// L3-R: who routes the tasks a release creates. Resolved at release time rather than passed
    /// to `init`: `SessionStore` builds this service lazily, and its routing is attached by
    /// `FlightDeckApp` after the store exists. nil releases tasks with no block; the launch-time
    /// re-route (L3-S) routes them then.
    var encodeRouting: () -> (any EncodeRoutingProviding)? = { nil }
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
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard,
        readFile: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) },
        announce: @escaping (String) -> Void = IntakeService.postAnnouncement
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
        self.defaults = defaults
        self.readFile = readFile
        self.announce = announce
        // Cheap-to-lose UI state, same durability class `UserDefaultsPreferencesPersistence`
        // argues for — unlike the session graph (`FileSessionPersistence`'s doc comment has
        // the fuller case for why THAT needs a file instead). Stored as path -> uuidString
        // since `UserDefaults` can't hold a `UUID` value directly.
        if let raw = defaults.dictionary(forKey: Self.selectionDefaultsKey) as? [String: String] {
            selectedIntake = raw.compactMapValues(UUID.init(uuidString:))
        }
        inspectorProjects = Set(defaults.stringArray(forKey: Self.inspectorDefaultsKey) ?? [])
        collapsedListProjects = Set(defaults.stringArray(forKey: Self.collapsedListDefaultsKey) ?? [])

        // Launch recovery: a turn or release in flight when FD quit has no process left to
        // finish it. Saying "triaging" forever would hide that; `.interrupted` asks the human.
        var loaded = store.all()
        for i in loaded.indices where loaded[i].state == .triaging || loaded[i].state == .releasing {
            let was = loaded[i].state
            loaded[i].state = .interrupted
            loaded[i].failure = was == .releasing
                ? "Flight Deck quit during release; some tasks may already be written — check `br list` before retrying."
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
        intakes(forProject: path).filter(needsAttention).count
    }

    /// The ONE attention rule — the sidebar's count, the phone's badge and banner all read it,
    /// so an intake cannot need you on one surface and not the other.
    func needsAttention(_ i: Intake) -> Bool {
        i.state.needsAttention || shapingNeedsAttention(i)
    }

    /// `project`'s selected intake, or nil when nothing is selected there OR the selection
    /// points at an intake that's gone — deleted from disk, or discarded (`intakes(forProject:)`
    /// already excludes those). Without the second check, discarding the selected intake would
    /// leave `selectedIntake` pointing at a row the list no longer draws, so the detail pane
    /// would keep showing a discarded intake instead of falling back to "Select an intake".
    func selection(forProject path: String) -> UUID? {
        guard let id = selectedIntake[Self.projectKey(path)],
              intakes(forProject: path).contains(where: { $0.id == id })
        else { return nil }
        return id
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
    ///
    /// Memoized on `commands.jsonl`'s stat and the ack, because the answer is a function of
    /// exactly those two and both callers ask on a schedule: the sidebar's attention count
    /// several times per redraw, and `resumeIfStalled` every tick. Each used to re-read and
    /// re-decode the whole file — ~2.6% of a core on the main thread (measured 2026-10-05).
    /// `appendCommand` always grows the file, so a queued command always moves the stamp.
    private func hasPendingCommands(_ id: UUID, _ tape: Tape) -> Bool {
        let store = tapeStore(id)
        let stamp = TranscriptStamp(of: store.commandsURL)
        if let memo = pendingCommandsMemo[id], memo.stamp == stamp, memo.acked == tape.ackedCommandSeq {
            return memo.pending
        }
        let pending = !store.commands(after: tape.ackedCommandSeq).isEmpty
        pendingCommandsMemo[id] = PendingCommandsMemo(
            stamp: stamp, acked: tape.ackedCommandSeq, pending: pending
        )
        return pending
    }

    /// The one split-flap memory for `id`'s screens — see `FlapPolicy` for why it can't live in
    /// the view. Created on first ask and seeded right then from the tape as it stands, so the
    /// answer can't depend on whether a view asked before or after launch recovery's first tick.
    /// A discarded or unknown intake gets a throwaway policy: storing one would keep memory for
    /// an intake nothing will show again.
    func flapPolicy(for id: UUID) -> FlapPolicy {
        guard let i = intake(id), i.state != .discarded else { return FlapPolicy() }
        let policy: FlapPolicy
        if let existing = flapPolicies[id] { policy = existing } else {
            policy = FlapPolicy()
            flapPolicies[id] = policy
        }
        seedFlapsIfNeeded(i, policy)
        return policy
    }

    /// The live task for `id`, if any — so tests (and nothing else) can await a turn.
    func task(for id: UUID) -> Task<Void, Never>? { tasks[id]?.task }

    /// Records `project`'s selected intake (nil clears it) and persists it, so a relaunch
    /// reopens each project on the intake the human was last looking at. `ProjectView` binds
    /// its List selection through this instead of local `@State` — see `selectedIntake`'s doc
    /// comment for the bug that state lost: SwiftUI resets `@State` on every project switch.
    func select(_ id: UUID?, inProject project: String) {
        selectedIntake[Self.projectKey(project)] = id
        defaults.set(selectedIntake.mapValues(\.uuidString), forKey: Self.selectionDefaultsKey)
    }

    /// Whether `project`'s detail pane shows its inspector — hidden until the human opens it
    /// (spec §3).
    func inspectorShown(forProject project: String) -> Bool {
        inspectorProjects.contains(Self.projectKey(project))
    }

    /// Opens or closes `project`'s inspector and persists it, alongside the selection and for
    /// the same reason — see `inspectorProjects`. A write that changes nothing is dropped, so the
    /// inspector re-asserting its own state doesn't republish every view observing this service.
    func setInspectorShown(_ shown: Bool, inProject project: String) {
        let key = Self.projectKey(project)
        guard inspectorProjects.contains(key) != shown else { return }
        if shown { inspectorProjects.insert(key) } else { inspectorProjects.remove(key) }
        defaults.set(inspectorProjects.sorted(), forKey: Self.inspectorDefaultsKey)
    }

    /// Whether `project`'s Intakes list is collapsed to its rail — expanded until the human
    /// collapses it.
    func intakeListCollapsed(forProject project: String) -> Bool {
        collapsedListProjects.contains(Self.projectKey(project))
    }

    /// Collapses or expands `project`'s Intakes list and persists it, as `setInspectorShown`
    /// does the inspector — and drops a write that changes nothing for the same reason.
    func setIntakeListCollapsed(_ collapsed: Bool, inProject project: String) {
        let key = Self.projectKey(project)
        guard collapsedListProjects.contains(key) != collapsed else { return }
        if collapsed { collapsedListProjects.insert(key) } else { collapsedListProjects.remove(key) }
        defaults.set(collapsedListProjects.sorted(), forKey: Self.collapsedListDefaultsKey)
    }

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
        pending[id] = PendingStart(kind: .triage, since: now())
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
            // The same optimistic start `answer` sets: without it the card drew the previous
            // turn's finished activity, clock stopped, until this turn wrote its first event.
            pending[id] = PendingStart(kind: .triage, since: now())
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
        // Before `startRunner`: a refusal fails the intake, and `save` then drops this again.
        pending[id] = PendingStart(kind: .round(upcomingRound(id, config: config)), since: now())
        startRunner(id)
    }

    /// The round a play is about to run: the one already in flight, else the planner's next.
    private func upcomingRound(_ id: UUID, config: RoundConfig?) -> PlannedRound? {
        let tape = latestTapes[id] ?? tapeStore(id).loadTape()
        return tape.roundInProgress ?? config.flatMap { TapePlanner.next(after: tape, config: $0) }
    }

    /// Queues `command` for the runner, then relaunches it for anything that asks for more
    /// rounds — a runner that paused, stopped or reached a target has exited, so "play" means
    /// a new one.
    ///
    /// `.stop` with no live runner also starts one, to CONSUME it: left queued, the stop sat
    /// unread until the next play spawned a runner, which then read the stop first and exited
    /// — the play the human just pressed did nothing. The runner applies it, writes `.stopped`
    /// and exits. `.pause` needs no such care (a later play overrides it, since commands
    /// apply in order), and a note is consumed by whichever round runs next. A note, its
    /// removal and a plan edit spawn nothing here either: with no live runner they read as
    /// unacked commands, which the next tick's `resumeIfStalled` starts one to fold in.
    ///
    /// A command that shapes the tape (`TapeOverlay.folds`) is also published in this same turn,
    /// ahead of the runner — before `startRunner`, which may block on a spawn.
    func send(_ id: UUID, _ command: TapeCommand) {
        guard intake(id)?.state == .shaping else { return }
        let seq: Int
        do { seq = try tapeStore(id).appendCommand(command) }
        catch { return fail(id, "Could not queue the command for the planning runner: \(error)") }
        if TapeOverlay.folds(command) {
            overlays[id, default: []].append(CommandEnvelope(seq: seq, command: command))
            publishTape(id, read: latestTapes[id] ?? tapeStore(id).loadTape())
        }
        switch command {
        case .note, .removeNote, .editPlan: return
        // A pause or stop withdraws the play that was starting: left pending, a runner that
        // reads the stop first and exits without a beat would leave "starting" up for good.
        case .pause:
            pending[id] = nil
            halts[id] = HaltRequest(kind: .pause, seq: seq)
        case .stop:
            pending[id] = nil
            halts[id] = HaltRequest(kind: .stop, seq: seq)
            if runner?.isRunning(id, tape: nil) != true { startRunner(id) }
        case .step, .nextMajor, .toReview:
            // A play queued after a pause overrides it (commands apply in order), so the bar
            // must stop saying "Pausing…" the moment the human changes their mind.
            halts[id] = nil
            pending[id] = PendingStart(kind: .round(upcomingRound(id, config: intake(id)?.roundConfig)), since: now())
            startRunner(id)
        case .extend, .trim: startRunner(id)
        }
    }

    /// Makes `mode` the intake's default play — what clicking a play button does besides
    /// playing (spec §4), and what the button's dot marks. Routed through
    /// `RoundConfigEditor.setting` like every Rounds-editor edit, so it flags `customized`.
    func setDefaultPlay(_ id: UUID, _ mode: PlayMode) {
        guard let config = intake(id)?.roundConfig, config.defaultPlay != mode else { return }
        mutate(id) { $0.roundConfig = RoundConfigEditor.setting(config) { $0.defaultPlay = mode } }
    }

    // MARK: - Phone commands (spec §6.5)

    /// The phone's refusals land in the fleet log beside `FleetService`'s own `check=` lines, so
    /// one `log stream --predicate 'category == "fleet"'` shows a whole phone exchange.
    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "fleet")

    /// Phone command tokens already accepted, per intake — a repeat is acked without being
    /// applied twice (a retry after a lost ack must not queue a second Step). Last 16 kept.
    private var phoneTokens: [UUID: [UUID]] = [:]
    static let maxRememberedPhoneTokens = 16

    /// Whether `token` was already accepted for `id`. Checked BEFORE validating: a retry after
    /// a lost ack meets the state its first delivery changed — the note it removed is gone, the
    /// tape it paused is paused — and validating that would refuse a command that in fact landed.
    private func alreadyAccepted(_ token: UUID, for id: UUID) -> Bool {
        phoneTokens[id]?.contains(token) == true
    }

    /// Remembers `token` as accepted — only once the command passed validation, so a refusal
    /// does not burn the token and a corrected retry with the same one still applies.
    private func accept(_ token: UUID, for id: UUID) {
        var seen = phoneTokens[id, default: []]
        seen.append(token)
        if seen.count > Self.maxRememberedPhoneTokens { seen.removeFirst(seen.count - Self.maxRememberedPhoneTokens) }
        phoneTokens[id] = seen
    }

    private func refuse(_ code: String, _ id: UUID) -> String {
        Self.logger.info("check=\(code, privacy: .public) intake=\(id, privacy: .public)")
        return code
    }

    /// The intake a phone command may act on, or the refusal code: `send` silently drops a
    /// command for an intake that has left shaping, so the phone is told instead.
    private func notShaping(_ id: UUID) -> String? {
        guard let i = intake(id) else { return refuse("unknown_intake", id) }
        return i.state == .shaping ? nil : refuse("intake_moved_on", id)
    }

    /// The phone's transport key (spec §6.5 `intakeTape`). Validated against the same
    /// `TransportRules` the desktop's control bar uses, so the phone cannot do what the Mac's
    /// own buttons would not. Returns nil when accepted, else a refusal code.
    func phoneTape(_ id: UUID, token: UUID, command: String, stage: String?) -> String? {
        if alreadyAccepted(token, for: id) { return nil }
        if let refusal = notShaping(id) { return refusal }
        let rules = TransportRules.make(tape: storedTape(id), config: intake(id)?.roundConfig)
        let tapeCommand: TapeCommand, button: TransportButton
        switch command {
        case "step": (tapeCommand, button) = (.step, .step)
        case "nextMajor": (tapeCommand, button) = (.nextMajor, .nextMajor)
        case "toReview": (tapeCommand, button) = (.toReview, .toReview)
        case "pause": (tapeCommand, button) = (.pause, .pause)
        case "stop": (tapeCommand, button) = (.stop, .stop)
        // ± carry the stage the phone was shown, and must still be the rule's: a phone acting on
        // a stale board would otherwise lengthen a stage the Mac has already moved past.
        case "extend":
            guard let s = rules.extendStage, stage == s.rawValue else { return refuse("not_allowed", id) }
            (tapeCommand, button) = (.extend(s, by: 1), .extend)
        case "trim":
            guard let s = rules.trimStage, stage == s.rawValue else { return refuse("not_allowed", id) }
            (tapeCommand, button) = (.trim(s, by: 1), .trim)
        default: return refuse("unknown_command", id)
        }
        guard rules.enabled.contains(button) else { return refuse("not_allowed", id) }
        accept(token, for: id)
        send(id, tapeCommand)
        return nil
    }

    /// The phone's choice of default play (spec §6.5 `intakeDefaultPlay`).
    func phoneDefaultPlay(_ id: UUID, token: UUID, mode: String) -> String? {
        if alreadyAccepted(token, for: id) { return nil }
        if let refusal = notShaping(id) { return refusal }
        guard let play = PlayMode(rawValue: mode) else { return refuse("unknown_mode", id) }
        accept(token, for: id)
        setDefaultPlay(id, play)
        return nil
    }

    /// A note from the phone (spec §6.5 `intakeNote`). The phone sends what it SHOWED — a block
    /// index and the rendered phrase — and the Mac builds the anchor from the markdown source,
    /// so the anchor is the same one the desktop's own highlight gesture would make. A phrase
    /// the source cannot be matched to anchors to its whole block: coarser, never the wrong one.
    func phoneNote(_ id: UUID, token: UUID, noteID: UUID, kind: String, text: String,
                   checkpoint: Int?, block: Int?, quote: String?) -> String? {
        if alreadyAccepted(token, for: id) { return nil }
        if let refusal = notShaping(id) { return refusal }
        // The backstop behind the token: a note id already pending IS this note, even under a
        // fresh token — a phone whose link dropped after the write may have lost the token it
        // sent it with — so it is acked without queuing a second copy.
        if pendingNotes(id).contains(where: { $0.id == noteID }) {
            accept(token, for: id)
            return nil
        }
        guard let noteKind = NoteKind(rawValue: kind) else { return refuse("unknown_kind", id) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty comment is a Highlight; every other kind says something or is not a note.
        guard !trimmed.isEmpty || noteKind == .comment else { return refuse("empty_note", id) }
        var anchor: NoteAnchor?
        if let checkpoint {
            let load: (Int, String) -> Data? = { self.checkpointFile(id, checkpoint: $0, $1) }
            guard let markdown = PlanSection.effectivePlan(checkpoint: checkpoint, tape: storedTape(id), loadFile: load)
            else { return refuse("unknown_checkpoint", id) }
            if let block {
                let blocks = PlanBlocks.split(markdown)
                guard let b = blocks.block(at: block) else { return refuse("unknown_block", id) }
                let scope = Self.occurrence(of: b, in: blocks, markdown: markdown)
                // A blank quote is no phrase: the whole block, as for nil, and not a fallback.
                let phrase = quote.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                let found = phrase.flatMap { RenderedQuoteLocator.range(of: $0, within: scope, of: markdown) }
                if phrase != nil, found == nil {
                    Self.logger.info("check=note_anchor_fallback intake=\(id, privacy: .public)")
                }
                anchor = NoteAnchor(checkpoint: checkpoint, selecting: found ?? scope, in: markdown)
            }
        } else if block != nil {
            return refuse("unknown_checkpoint", id)
        }
        accept(token, for: id)
        send(id, .note(PlanNote(id: noteID, kind: noteKind, note: trimmed, anchor: anchor)))
        return nil
    }

    /// The phone withdrawing a note it added (spec §6.5 `intakeRemoveNote`) — only while it is
    /// still pending: a note a round has read has already shaped the plan.
    func phoneRemoveNote(_ id: UUID, token: UUID, noteID: UUID) -> String? {
        if alreadyAccepted(token, for: id) { return nil }
        if let refusal = notShaping(id) { return refusal }
        guard pendingNotes(id).contains(where: { $0.id == noteID }) else { return refuse("note_consumed", id) }
        accept(token, for: id)
        send(id, .removeNote(noteID))
        return nil
    }

    /// `id`'s notes no round has read yet: the tape's pending notes with the queued note commands
    /// no runner has acked folded on top. `TapeOverlay` does not fold notes, so a note sent a
    /// moment ago is only a line in `commands.jsonl` until a runner reads it — and withdrawing it
    /// then is exactly the phone's undo, which must not be refused as consumed.
    private func pendingNotes(_ id: UUID) -> [PlanNote] {
        let tape = storedTape(id)
        return tapeStore(id).commands(after: tape.ackedCommandSeq).reduce(into: tape.pendingNotes) { notes, queued in
            switch queued.command {
            case .note(let note): notes.append(note)
            case .removeNote(let withdrawn): notes.removeAll { $0.id == withdrawn }
            default: break
            }
        }
    }

    /// Block `b`'s own place in `markdown`, found by walking every block up to it in order, each
    /// search starting where the previous hit ended. Block text is verbatim source, but a bare
    /// search matches substrings: `- TBD` would be found inside an earlier `- TBD later`, or a
    /// paragraph `Scope` inside `## Scope`, and the note anchored on the wrong passage. Walking
    /// the blocks in order also takes the second of two identical items for the second.
    /// The whole plan if a search fails, which `split` makes impossible in practice.
    static func occurrence(of b: PlanBlocks.Block, in blocks: PlanBlocks, markdown: String) -> Range<String.Index> {
        let whole = markdown.startIndex..<markdown.endIndex
        var from = markdown.startIndex
        for block in blocks.blocks.prefix(b.index + 1) {
            guard let hit = markdown.range(of: block.text, range: from..<markdown.endIndex) else { return whole }
            if block.index == b.index { return hit }
            from = hit.upperBound
        }
        return whole
    }

    /// Which models planning rounds can seat: the PATH probe triage uses, run off the main
    /// actor by `init`. Until that lands, the stock both-harness defaults — never a blocking
    /// login-shell lookup on the main actor. A default naming a harness this machine lacks
    /// is not silent: its round fails and falls back or pauses with a diagnosis.
    func availableModels() -> AvailableModels {
        availableModelsCache ?? .defaults
    }

    func markEditNoteShown(_ id: UUID) { editNoteShown.insert(id) }

    /// Intake `id`'s plan-edit router, made on first use and kept while it shapes.
    func editRouter(_ id: UUID) -> PlanEditRouter {
        if let router = editRouters[id] { return router }
        let router = PlanEditRouter()
        editRouters[id] = router
        return router
    }

    /// Intake `id`'s folded plan sections, made on first use and kept while it shapes — so an
    /// intake switch, which rebuilds the editor, comes back to the plan folded as it was left.
    func planFolds(_ id: UUID) -> PlanFoldStore {
        if let store = planFoldStores[id] { return store }
        let store = PlanFoldStore()
        planFoldStores[id] = store
        return store
    }

    func recordEditConflict(_ id: UUID, _ conflict: EditConflict) {
        editConflicts[id, default: []].append(conflict)
    }

    /// The live card's conflict banner for `id`'s plan head `head`: the runner's conflicts
    /// and the app's, newest last.
    func editConflictNotice(_ id: UUID, tape: Tape, head: Int?) -> EditConflictNotice? {
        let names = { (checkpoint: Int) in
            tape.checkpoints.first { $0.id == checkpoint }.map(PlanSection.checkpointName) ?? "checkpoint \(checkpoint)"
        }
        return EditLayer.conflictNotice(PlanLayers.conflictedEdits(tape) + (editConflicts[id] ?? []), head: head, names: names)
    }

    /// A file a round wrote into `checkpoints/<checkpoint>/` — the plan section's `loadFile`.
    /// A synchronous read on the main actor: fine at plan sizes (a plan, a change set, a
    /// graph — kilobytes), and `PlanSection` only calls it when its viewer key changes.
    func checkpointFile(_ id: UUID, checkpoint: Int, _ path: String) -> Data? {
        readFile(tapeStore(id).checkpointDirectory(checkpoint).appendingPathComponent(path))
    }

    /// `id`'s tape as it stands: the polled copy while shaping, else read from disk — `tapes`
    /// drops an intake once it leaves shaping, and the review's final plan still needs it.
    func storedTape(_ id: UUID) -> Tape {
        tapes[id] ?? latestTapes[id] ?? tapeStore(id).loadTape()
    }

    /// `runs/<run>/` for one of `id`'s seats — what the inspector's seat detail shows and
    /// reveals in the Finder.
    func runDirectory(_ id: UUID, run: String) -> URL {
        tapeStore(id).runDirectory(run)
    }

    /// Every note on `id`'s published tape — consumed ones with the round that read them, then
    /// the pending ones — for the notes rail and the plan's highlights. In memory, no file read.
    func notes(_ id: UUID) -> [TapeNote] {
        tapes[id].map { tapeStore(id).notes(in: $0) } ?? []
    }

    /// How many notes a round consumed on `id`'s tape, once shaping has ended too
    /// (`storedTape`'s disk fallback, unlike `notes(_:)` above) — the release review's "N
    /// notes carried into task notes" (spec §10).
    func consumedNotesCount(_ id: UUID) -> Int {
        tapeStore(id).notes(in: storedTape(id)).lazy.filter { $0.consumedBy != nil }.count
    }

    /// One clock beat: re-read the tape of every `.shaping` intake whose `tape.json` changed
    /// since the last read (one stat each when nothing did), publish it, move a tape that
    /// reached review into release review, bring back a runner that died mid-work, and collect
    /// any daemon queued in `pendingReaps` that has stopped running. The same beat follows the
    /// round in progress's seats (`pollSeats`), refolds convergence when a round lands, and
    /// settles pending starts — one clock for all of it, never a second timer. Also run once by
    /// launch recovery, which is what makes a relaunch resume.
    func pollTapes() {
        let shaping = Set(intakes.lazy.filter { $0.state == .shaping }.map(\.id))
        let tracked = Set(latestTapes.keys).union(tapes.keys).union(tapeDates.keys).union(seatRounds.keys)
            .union(seatActivities.keys).union(runRecords.keys).union(seatResults.keys).union(convergence.keys)
            .union(convergenceKeys.keys).union(coverage.keys).union(halts.keys).union(editConflicts.keys).union(editRouters.keys).union(planFoldStores.keys)
            .union(overlays.keys).union(pendingCommandsMemo.keys)
        for gone in tracked.subtracting(shaping) {
            tapes[gone] = nil
            overlays[gone] = nil
            pendingCommandsMemo[gone] = nil
            latestTapes[gone] = nil
            tapeDates[gone] = nil
            forgetSeats(gone)
            convergence[gone] = nil
            convergenceKeys[gone] = nil
            convergenceFolds[gone] = nil
            coverage[gone] = nil
            halts[gone] = nil
            editConflicts[gone] = nil
            editRouters[gone] = nil
            planFoldStores[gone] = nil
        }
        for id in shaping {
            let store = tapeStore(id)
            let modified = (try? FileManager.default.attributesOfItem(atPath: store.tapeURL.path))?[.modificationDate] as? Date
            if latestTapes[id] == nil || modified != tapeDates[id] {
                tapeDates[id] = modified
                let tape = store.loadTape()
                if let words = Self.announcement(from: latestTapes[id], to: tape) { announce(words) }
                latestTapes[id] = tape
                publishTape(id, read: tape)
            }
            // Already seeded (a view asked first) is skipped: the values since then were observed.
            if !flapSeeded.contains(id) { _ = flapPolicy(for: id) }
            refreshConvergence(id)
            pollSeats(id)
            if let halt = halts[id], let acked = latestTapes[id]?.ackedCommandSeq, acked >= halt.seq { halts[id] = nil }
            if latestTapes[id]?.status == .reachedReview { finishShaping(id) } else { resumeIfStalled(id) }
        }
        pollTriageActivity()
        settlePending()
        if let runner {
            for id in pendingReaps where !runner.isRunning(id, tape: nil) {
                runner.reap(id)
                pendingReaps.remove(id)
            }
        }
    }

    /// Re-reads the round in progress's `runs/<run>/activity.json`, `run.json` and `result.json`, each gated on
    /// its own mtime. Nothing is read while the tape has no round in progress: every run on disk
    /// then belongs to a round that already landed (or was thrown away), which the finished
    /// cards draw from the checkpoint instead.
    private func pollSeats(_ id: UUID) {
        guard let round = latestTapes[id]?.roundInProgress else { return forgetSeats(id) }
        if seatRounds[id] != round {
            forgetSeats(id)
            seatRounds[id] = round
        }
        let store = tapeStore(id)
        var activities = seatActivities[id] ?? [:], records = runRecords[id] ?? [:], results = seatResults[id] ?? [:]
        for run in store.runNames(forRound: round) {
            let dir = store.runDirectory(run)
            if let activity: SeatActivity = readIfModified(id, dir.appendingPathComponent("activity.json")) {
                activities[run] = activity
            }
            if let record: RunRecord = readIfModified(id, dir.appendingPathComponent("run.json")) {
                records[run] = record
            }
            if let result: SeatResult = readIfModified(id, dir.appendingPathComponent("result.json")) {
                results[run] = result
            }
        }
        // A retried round keeps its `PlannedRound`, so the failed attempt's seats are still under
        // the same run names (a fallback seat's own directory is never overwritten). Anything
        // that started before this attempt did is history, not a seat at work.
        if let floor = latestTapes[id]?.roundStartedAt?.addingTimeInterval(-1) {
            activities = activities.filter { $0.value.startedAt >= floor }
            records = records.filter { $0.value.started >= floor }
            // A result carries no clock of its own; it belongs to this attempt only if its run
            // does — else the failed attempt's outcome would sit on the retried seat's row.
            results = results.filter { activities[$0.key] != nil || records[$0.key] != nil }
        }
        // Compared first: republishing an unchanged map would redraw every observer each tick.
        if activities != seatActivities[id] ?? [:] { seatActivities[id] = activities }
        if records != runRecords[id] ?? [:] { runRecords[id] = records }
        if results != seatResults[id] ?? [:] { seatResults[id] = results }
    }

    /// `file` decoded, only when its mtime moved since the last read; nil otherwise (unchanged,
    /// absent, or not decodable — a torn write is re-read when its replacement lands).
    private func readIfModified<T: Decodable>(_ id: UUID, _ file: URL) -> T? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              modified != seatFileDates[id]?[file.path] else { return nil }
        seatFileDates[id, default: [:]][file.path] = modified
        return readFile(file).flatMap { try? IntakeJSON.decoder.decode(T.self, from: $0) }
    }

    private func forgetSeats(_ id: UUID) {
        if seatActivities[id] != nil { seatActivities[id] = nil }
        if runRecords[id] != nil { runRecords[id] = nil }
        if seatResults[id] != nil { seatResults[id] = nil }
        seatFileDates[id] = nil
        seatRounds[id] = nil
    }

    /// Refolds `convergence` when its key moved (see `convergenceKeys`) — one stat a tick
    /// otherwise. The fold itself runs detached: it diffs every refine/polish plan pair, which
    /// on a long tape is real work to do on the main actor every time a round lands. A result
    /// whose key has since moved on is dropped rather than published over a newer one.
    private func refreshConvergence(_ id: UUID) {
        guard let tape = latestTapes[id] else { return }
        let store = tapeStore(id)
        let edits = store.headPlanCheckpoint(in: tape).flatMap {
            (try? FileManager.default.attributesOfItem(atPath: store.userEditsURL(checkpoint: $0).path))?[.modificationDate] as? Date
        }
        let key = ConvergenceKey(count: tape.checkpoints.count, userEdits: edits)
        guard convergenceKeys[id] != key else { return }
        convergenceKeys[id] = key
        let checkpoints = tape.checkpoints, readFile = readFile
        convergenceFolds[id] = Task.detached(priority: .utility) { [weak self] in
            let cycles = ConvergenceSeries.cycles(checkpoints) {
                readFile(store.checkpointDirectory($0).appendingPathComponent($1))
            }
            let readings = CoverageSeries.readings(checkpoints) {
                readFile(store.checkpointDirectory($0).appendingPathComponent($1))
            }
            await MainActor.run { [weak self] in
                guard let self, self.convergenceKeys[id] == key else { return }
                if self.convergence[id] != cycles {
                    let first = self.convergence[id] == nil
                    self.convergence[id] = cycles
                    // The first series is not news: it was true before anyone looked, and the board
                    // was seeded without it (it is folded after). Later ones flap as they change.
                    if first, self.flapSeeded.contains(id), let word = ConvergenceCellModel(cycles: cycles)?.word {
                        self.flapPolicies[id]?.seed(surface: "lcd.convergence", text: word)
                    }
                }
                if self.coverage[id] != readings {
                    let first = self.coverage[id] == nil
                    self.coverage[id] = readings
                    // As with the CONVERGENCE word: the first readings were true before anyone
                    // looked, so the word they make is seeded rather than flapped in.
                    if first, self.flapSeeded.contains(id), let intake = self.intake(id), let config = intake.roundConfig,
                       let word = CoverageCellModel(intake: intake, tape: tape, config: config, readings: readings,
                                                    cycles: self.convergence[id] ?? [])?.word {
                        self.flapPolicies[id]?.seed(surface: "lcd.coverage", text: word)
                    }
                }
            }
        }
    }

    /// The convergence fold in flight for `id`, if any — so tests (and nothing else) can await it.
    func convergenceFold(for id: UUID) -> Task<Void, Never>? { convergenceFolds[id] }

    /// Marks everything the board shows right now as already shown (see `FlapPolicy.seed`), once
    /// per intake, from the tape as last read or straight off disk. Without it the first mount of
    /// the board flapped every field, replaying values that had been on the tape for hours. Not
    /// marked seeded until the intake is shaping: before then there is no board to seed.
    private func seedFlapsIfNeeded(_ i: Intake, _ policy: FlapPolicy) {
        guard !flapSeeded.contains(i.id), i.state == .shaping, let config = i.roundConfig else { return }
        flapSeeded.insert(i.id)
        let tape = latestTapes[i.id] ?? tapeStore(i.id).loadTape()
        let board = BoardModel(intake: i, tape: tape, config: config, now: now(), selected: nil, preview: nil)
        // The LCD's text values too, the CONVERGENCE and COVERAGE words included once their
        // series are known; a series folded after this is seeded as it lands (`refreshConvergence`).
        let lcd = LCDModel(tape: tape, config: config, board: board, seats: [],
                           convergence: convergence[i.id].flatMap { ConvergenceCellModel(cycles: $0) },
                           coverage: coverage[i.id].flatMap { CoverageCellModel(intake: i, tape: tape, config: config, readings: $0,
                                                                                 cycles: convergence[i.id] ?? []) },
                           preview: nil, now: now())
        for (surface, text) in board.flapTexts.merging(lcd.flapTexts, uniquingKeysWith: { a, _ in a }) {
            policy.seed(surface: surface, text: text)
        }
    }

    /// Clears every pending start whose work has shown a sign of life, and turns one silent for
    /// `queuedAfter` into the quiet queued state.
    private func settlePending() {
        let clock = now()
        for (id, start) in pending {
            if heardFrom(id, since: start) {
                pending[id] = nil
            } else if !start.queued, clock.timeIntervalSince(start.since) >= Self.queuedAfter {
                pending[id]?.queued = true
            }
        }
    }

    /// Activity or a heartbeat dated at or after the click — or, for a round, a tape the runner
    /// rewrote since the click into anything but `.idle`. Dated, not merely present: the
    /// previous turn's `activity.json` or a dead runner's last heartbeat is still on disk when
    /// the click lands, and counting it would clear "starting" before anything started. The
    /// tape rule catches a runner that adopted the play and already finished (paused, stopped,
    /// failed, reached review) between two ticks: its exit clears the heartbeat and the round's
    /// seats are gone with `roundInProgress`, so without it "queued" stuck for good. A second's
    /// grace absorbs the millisecond rounding those dates are stored with.
    private func heardFrom(_ id: UUID, since start: PendingStart) -> Bool {
        let after = start.since.addingTimeInterval(-1)
        switch start.kind {
        case .triage:
            return (triageActivities[id]?.startedAt).map { $0 >= after } ?? false
        case .round:
            if let beat = latestTapes[id]?.heartbeat, beat >= after { return true }
            if let written = tapeDates[id], written >= after, let status = latestTapes[id]?.status, status != .idle {
                return true
            }
            return seatActivities[id]?.values.contains { $0.startedAt >= after } ?? false
        }
    }

    /// Publishes `read` — the runner's tape — with the overlay commands it hasn't acked replayed
    /// on top, dropping the ones it has. The one writer of `tapes` for a shaping intake, so a
    /// click and a tick can't publish two different answers.
    private func publishTape(_ id: UUID, read: Tape) {
        let unacked = TapeOverlay.unconsumed(overlays[id] ?? [], by: read)
        overlays[id] = unacked.isEmpty ? nil : unacked
        let shown = TapeOverlay.applying(unacked, to: read, config: intake(id)?.roundConfig)
        if tapes[id].map({ !Self.sameIgnoringLiveness($0, shown) }) ?? true { tapes[id] = shown }
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
        // After the save, which drops a triage start for any state but `.triaging`; the turn's
        // own `.triaging` save keeps it. The failed turn's activity goes with it — it is not
        // this turn's, and the card would otherwise draw it as a finished seat.
        pending[id] = PendingStart(kind: .triage, since: now())
        triageActivities[id] = nil
        triageActivityDates[id] = nil
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
        flapPolicies[id] = nil
        flapSeeded.remove(id)
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
        // The triage-time graph first, the live one over it: a task retitled since triage reads
        // as it is now, and one deleted since still has a name on its (impossible) row.
        review.titles = triaged.beads.mapValues(\.title).merging(current.beads.mapValues(\.title)) { _, now in now }
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
        catch { return fail(id, backTo: .review, "Could not read the task graph before release: \(error)") }
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
                                + errs.errors.map(\.userMessage).joined(separator: "; "))
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
        // Routed before the first write, so a create lands with its block in one `br create`
        // instead of a create plus an update that a failure between them could split.
        let contexts = await encodeRouting()?.agentContexts(for: steps, project: i.projectPath) ?? [:]
        // Routing suspends, and the guard above ran before it: a release discarded or retried
        // while the router was working would otherwise still write its tasks.
        guard !Task.isCancelled else { return }
        let outcome = await BeadWriter(runner: processRunner, brPath: brPath, actor: actor)
            .apply(steps, project: i.projectPath, agentContexts: contexts)

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

    // MARK: - Announcements

    /// What VoiceOver hears when a tape moves (spec §14): a round landed, or failed. Nil for the
    /// first read — that is the app opening onto a tape, not a change — and for everything else
    /// a tick brings (heartbeats, a round starting, pauses), which would be chatter.
    static func announcement(from old: Tape?, to new: Tape) -> String? {
        guard let old else { return nil }
        if new.status == .failed, old.status != .failed {
            guard let round = new.roundInProgress ?? old.roundInProgress else { return "A planning round failed" }
            return "\(BoardModel.name(stage: round.stage, round: round.round)) failed"
        }
        // The last round landing at review is said once, by the intake's own move to `.review`
        // ("ready for review") — two announcements in one tick cut each other off.
        if let head = new.head, head.id != old.head?.id, new.status != .reachedReview {
            return "\(BoardModel.name(stage: head.stage, round: head.round)) landed"
        }
        return nil
    }

    /// What VoiceOver hears when an intake changes state (spec §14): it needs you (questions,
    /// a plan to review) or it failed. Nothing for the states a human started themselves.
    static func announcement(from old: IntakeState?, to new: IntakeState) -> String? {
        guard let old, old != new else { return nil }
        switch new {
        case .needsAnswers: return "Triage has questions for you"
        case .review: return "The plan is ready for review"
        case .failed: return "The intake failed"
        default: return nil
        }
    }

    /// The app's announcer: a high-priority `announcementRequested` on the key window, so it
    /// interrupts nothing less urgent but is not queued behind the per-second clocks it never
    /// reads out (those are only labels, spec §14).
    static func postAnnouncement(_ text: String) {
        guard let element = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Triage

    /// What the triage agent is doing right now, or last did — `triage/activity.json` as of
    /// the last clock tick that found it changed (`pollTriageActivity`), and the finished fold
    /// the moment a turn ends. nil until a triage turn has started this session.
    func triageActivity(_ id: UUID) -> SeatActivity? { triageActivities[id] }

    /// Re-reads `triage/activity.json` for every intake mid-triage, gated on its mtime so an
    /// idle tick costs one stat per triaging intake — same rule `pollTapes` holds `tape.json`
    /// to. Only `.triaging` intakes are polled: any other intake's file is either a finished
    /// turn, already published by `turnResult`, or one from before a relaunch.
    private func pollTriageActivity() {
        let live = Set(intakes.lazy.filter { $0.state != .discarded }.map(\.id))
        for gone in Set(triageActivities.keys).union(triageActivityDates.keys).subtracting(live) {
            triageActivities[gone] = nil
            triageActivityDates[gone] = nil
        }
        for i in intakes where i.state == .triaging {
            let file = triageDirectory(i.id).appendingPathComponent("activity.json")
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                  modified != triageActivityDates[i.id] else { continue }
            triageActivityDates[i.id] = modified
            guard let data = readFile(file),
                  let activity = try? IntakeJSON.decoder.decode(SeatActivity.self, from: data),
                  activity != triageActivities[i.id] else { continue }
            triageActivities[i.id] = activity
        }
    }

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
        catch { return fail(id, "Could not read the task graph: \(error)") }
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

        var reply = await turnResult(id, prompt: prompt, resume: resume, settings: session, files: files, project: project)
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
                reply = await turnResult(id, prompt: Triage.correctionPrompt(errors: errs.errors, observedAt: observedAt),
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
                                    + errs2.errors.map(\.userMessage).joined(separator: "; "), raw: second.raw)
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
                return fail(id, "Asked to encode at \(UIText.presetName(.bead)) fidelity, but the reply carried no change set.", raw: result.raw)
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
    private func turnResult(_ id: UUID, prompt: String, resume: String?, settings: TriageSettings,
                            files: TriageFiles, project: URL) async -> Result<TurnReply, TurnFailure> {
        let request = HarnessRequest(
            harness: settings.harness, model: settings.model, effort: settings.effort, cwd: project,
            readableDirs: [files.directory], prompt: prompt, schemaFile: files.schema,
            schemaJSON: Triage.schemaJSON, resumeSessionID: resume)
        // The same fold and cadence as a round's seats (`RoundExecutor.attempt`), written beside
        // triage's other files; the clock tick reads it back (`pollTriageActivity`), and the
        // finished fold is published directly below so the last state never waits on a tick.
        let activity = ActivityPublisher(harness: settings.harness, project: project,
                                         destination: files.directory.appendingPathComponent("activity.json"),
                                         now: { Date() })
        activity.start()
        let out: (stdout: Data, stderr: String, exitCode: Int32)
        do {
            out = try await headless.run(HarnessCommand.build(request), cwd: project,
                                         onStdout: { activity.feed($0) })
        } catch {
            activity.finish(exitCode: nil, error: Task.isCancelled ? nil : "Could not run \(settings.harness.rawValue)")
            triageActivities[id] = activity.activity
            return .failure(TurnFailure(message: "Could not run \(settings.harness.rawValue): \(error)", raw: nil))
        }
        activity.finish(exitCode: out.exitCode)
        triageActivities[id] = activity.activity
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
            agentsFile: existing("AGENTS.md"), readmeFile: existing("README.md"), observedAt: observedAt,
            kinds: KindRegistryStore.promptKinds(project: URL(fileURLWithPath: i.projectPath, isDirectory: true)))
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
    ///
    /// Also where a pending start ends when its work never began: a triage turn that failed
    /// before writing any activity, a runner that refused to start, a discard. Only `.triaging`
    /// keeps a triage start (`answer` saves before it sets one), only `.shaping` a round's.
    private func save(_ intake: Intake) {
        try? store.save(intake)
        if let n = intakes.firstIndex(where: { $0.id == intake.id }) {
            if let words = Self.announcement(from: intakes[n].state, to: intake.state) { announce(words) }
            intakes[n] = intake
        } else {
            intakes.insert(intake, at: 0)
        }
        if let start = pending[intake.id] {
            let keeps = switch start.kind {
            case .triage: intake.state == .triaging
            case .round: intake.state == .shaping
            }
            if !keeps { pending[intake.id] = nil }
        }
    }
}
