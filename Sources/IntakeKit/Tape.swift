import Foundation

/// A stop the round engine can land on. `draft`/`synthesis`/`encode`/`freshEyes`/`dedup` each
/// run exactly once per tape (round 0); `refine` and `polish` repeat 1...N, capped by
/// `RoundConfig.refinementCap`/`polishCap` plus whatever `.extend` has added on top.
public enum Stage: String, Codable, Sendable { case draft, synthesis, refine, encode, polish, freshEyes, dedup }

/// How a review round's verdicts split, for the summary a human sees before deciding whether
/// to extend refinement.
public struct VerdictTally: Codable, Equatable, Sendable {
    public var agree: Int
    public var somewhat: Int
    public var disagree: Int
    public init(agree: Int = 0, somewhat: Int = 0, disagree: Int = 0) {
        self.agree = agree
        self.somewhat = somewhat
        self.disagree = disagree
    }
}

/// What `FailureDiagnosis` (Task 5) classified a harness failure as, and what the runner did
/// about it — shown to the human when a round paused instead of a clean stop.
public enum DiagnosisCategory: String, Codable, Sendable { case rateLimited, authExpired, timeout, harnessError, invalidOutput }

public struct Diagnosis: Codable, Equatable, Sendable {
    public var category: DiagnosisCategory
    public var detail: String
    public var action: String
    public init(category: DiagnosisCategory, detail: String, action: String) {
        self.category = category
        self.detail = detail
        self.action = action
    }
}

/// Whether a seat ran as requested, fell back to its slot's backup model, or failed outright.
public enum SlotStatus: String, Codable, Sendable { case ok, substituted, failed }

/// One seat's outcome within a round — the model that actually ran (`used`) may differ from
/// what the config asked for (`requested`) when a fallback fired.
public struct SlotOutcome: Codable, Equatable, Sendable {
    public var role: String            // "drafter", "synthesizer", "reviewer", "integrator", "encoder", "polisher"
    public var persona: DrafterPersona?
    public var used: ModelChoice
    public var requested: ModelChoice
    public var status: SlotStatus
    public var diagnosis: Diagnosis?
    public var sessionID: String?
    public init(role: String, persona: DrafterPersona? = nil, used: ModelChoice, requested: ModelChoice,
                status: SlotStatus, diagnosis: Diagnosis? = nil, sessionID: String? = nil) {
        self.role = role
        self.persona = persona
        self.used = used
        self.requested = requested
        self.status = status
        self.diagnosis = diagnosis
        self.sessionID = sessionID
    }
}

/// What one round actually produced — the durable payload a `Checkpoint` carries. Fields not
/// relevant to a given stage (e.g. `tally` outside review, `changeCount` in a draft round)
/// are left at their defaults rather than made stage-specific types,
/// so the shape stays uniform across the tape.
public struct RoundRecord: Codable, Equatable, Sendable {
    public var slots: [SlotOutcome]
    public var changeCount: Int?        // proposed changes (review/synthesis), ops.count (encode), or ops changed (polish/freshEyes/dedup, edges included)
    public var linesAdded: Int
    public var linesRemoved: Int
    public var sectionsChanged: [String]
    public var tally: VerdictTally?
    /// The human's notes this round consumed — every one pending when it started, since every
    /// stage's prompt carries them all.
    public var annotations: [PlanNote]
    public var note: String?
    /// The checkpoint whose mid-round edits could not be carried forward onto this round's plan
    /// (a merge conflict, or a merge tool that failed) — they are still there, unapplied. See
    /// `PlanLayers.conflictedEdits`.
    public var editConflict: Int?
    /// Polish, fresh-eyes and dedup: the dependency-edge share of `changeCount`
    /// (`PlanMetrics.edgesChanged`). nil for every other stage, and on a record written before
    /// it existed.
    public var edgesChanged: Int?
    public init(slots: [SlotOutcome] = [], changeCount: Int? = nil, linesAdded: Int = 0, linesRemoved: Int = 0,
                sectionsChanged: [String] = [], tally: VerdictTally? = nil, annotations: [PlanNote] = [], note: String? = nil,
                editConflict: Int? = nil, edgesChanged: Int? = nil) {
        self.slots = slots
        self.changeCount = changeCount
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.sectionsChanged = sectionsChanged
        self.tally = tally
        self.annotations = annotations
        self.note = note
        self.editConflict = editConflict
        self.edgesChanged = edgesChanged
    }

    private enum CodingKeys: String, CodingKey {
        case slots, changeCount, linesAdded, linesRemoved, sectionsChanged, tally, annotations, note, editConflict,
             edgesChanged
    }

    /// Synthesized but for `annotations`, which a tape written before `PlanNote` holds as bare
    /// strings — those come back as the unanchored comments they were.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decode([SlotOutcome].self, forKey: .slots)
        changeCount = try c.decodeIfPresent(Int.self, forKey: .changeCount)
        linesAdded = try c.decode(Int.self, forKey: .linesAdded)
        linesRemoved = try c.decode(Int.self, forKey: .linesRemoved)
        sectionsChanged = try c.decode([String].self, forKey: .sectionsChanged)
        tally = try c.decodeIfPresent(VerdictTally.self, forKey: .tally)
        annotations = try decodeNotes(c, .annotations) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        editConflict = try c.decodeIfPresent(Int.self, forKey: .editConflict)
        edgesChanged = try c.decodeIfPresent(Int.self, forKey: .edgesChanged)
    }
}

/// `[PlanNote]` under `key`, or the pre-`PlanNote` `[String]` shape mapped through
/// `PlanNote.legacy`; nil when the key is absent.
private func decodeNotes<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> [PlanNote]? {
    guard c.contains(key) else { return nil }
    if let notes = try? c.decode([PlanNote].self, forKey: key) { return notes }
    return try c.decode([String].self, forKey: key).enumerated().map { PlanNote.legacy($1, index: $0) }
}

/// One entry on the tape. `id` is sequential starting at 1 and `parent` is the head it grew
/// from — both assigned by `RoundExecutor.run` from the tape it was handed (`writeCheckpoint`
/// only stores what it is given); `major` marks a stage boundary a "Continue to next major"
/// click is allowed to stop on.
public struct Checkpoint: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var parent: Int?
    public var stage: Stage
    public var round: Int
    public var major: Bool
    public var createdAt: Date
    public var record: RoundRecord
    public init(id: Int, parent: Int? = nil, stage: Stage, round: Int, major: Bool, createdAt: Date, record: RoundRecord = RoundRecord()) {
        self.id = id
        self.parent = parent
        self.stage = stage
        self.round = round
        self.major = major
        // Round to milliseconds — see `millisecondRounded`'s doc comment.
        self.createdAt = millisecondRounded(createdAt)
        self.record = record
    }
}

/// `IntakeJSON`'s date strategy (ISO8601 with fractional seconds) only preserves millisecond
/// precision, so an unrounded `Date()` — which carries sub-millisecond precision on this
/// platform — would not equal itself after a save/load round trip through `TapeStore`. Same
/// fix as `Intake.init`'s createdAt rounding, applied here to `Checkpoint.createdAt` and
/// `Tape.heartbeat`, the two `Date` fields that go through `TapeStore`.
private func millisecondRounded(_ date: Date) -> Date {
    let interval = date.timeIntervalSince1970
    return Date(timeIntervalSince1970: (interval * 1000).rounded() / 1000)
}

/// How far the runner is allowed to go before it stops and hands back to the human — the
/// live, adjustable counterpart to `RoundConfig.defaultPlay`.
public enum TapeTarget: String, Codable, Sendable { case none, nextMinor, nextMajor, review }

public enum RunnerStatus: String, Codable, Sendable { case idle, running, paused, failed, reachedReview, stopped }

/// The next round the runner is mid-way through, so a restart after a crash knows what was in
/// flight rather than re-deriving it from `TapePlanner` (which would run it as a fresh round,
/// not resume it).
public struct PlannedRound: Codable, Equatable, Sendable {
    public var stage: Stage
    public var round: Int
    public var major: Bool
    public init(stage: Stage, round: Int, major: Bool) {
        self.stage = stage
        self.round = round
        self.major = major
    }
}

/// The full state of one intake's shaping run: every checkpoint reached so far, plus the
/// live control state (`target`, `status`, pending commands) the app and the detached runner
/// both read and write. `head` is the tape's current position — linear for this plan; a
/// future branch feature would need something richer than "last element".
public struct Tape: Codable, Equatable, Sendable {
    public var checkpoints: [Checkpoint]
    public var target: TapeTarget
    public var status: RunnerStatus
    public var pauseDiagnosis: Diagnosis?
    public var ackedCommandSeq: Int
    public var extraRefinement: Int
    public var extraPolish: Int
    /// Notes queued for the next round (✎ and anchored highlights alike); the round that runs
    /// next consumes them all, and its record lists them.
    public var pendingNotes: [PlanNote]
    public var runnerPID: Int32?
    public var heartbeat: Date?
    public var roundInProgress: PlannedRound?

    public init(checkpoints: [Checkpoint] = [], target: TapeTarget = .none, status: RunnerStatus = .idle,
                pauseDiagnosis: Diagnosis? = nil, ackedCommandSeq: Int = 0, extraRefinement: Int = 0,
                extraPolish: Int = 0, pendingNotes: [PlanNote] = [], runnerPID: Int32? = nil,
                heartbeat: Date? = nil, roundInProgress: PlannedRound? = nil) {
        self.checkpoints = checkpoints
        self.target = target
        self.status = status
        self.pauseDiagnosis = pauseDiagnosis
        self.ackedCommandSeq = ackedCommandSeq
        self.extraRefinement = extraRefinement
        self.extraPolish = extraPolish
        self.pendingNotes = pendingNotes
        self.runnerPID = runnerPID
        self.heartbeat = heartbeat.map(millisecondRounded)
        self.roundInProgress = roundInProgress
    }

    private enum CodingKeys: String, CodingKey {
        case checkpoints, target, status, pauseDiagnosis, ackedCommandSeq, extraRefinement, extraPolish,
             pendingNotes, runnerPID, heartbeat, roundInProgress
        /// Read-only: what `pendingNotes` was called when notes were bare strings.
        case pendingAnnotations
    }

    /// Synthesized but for the notes: a tape written before `PlanNote` has `pendingAnnotations`
    /// strings instead, migrated to unanchored comments — and saved back as `pendingNotes` by
    /// the runner's next write, since `encode` never writes the old key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkpoints = try c.decode([Checkpoint].self, forKey: .checkpoints)
        target = try c.decode(TapeTarget.self, forKey: .target)
        status = try c.decode(RunnerStatus.self, forKey: .status)
        pauseDiagnosis = try c.decodeIfPresent(Diagnosis.self, forKey: .pauseDiagnosis)
        ackedCommandSeq = try c.decode(Int.self, forKey: .ackedCommandSeq)
        extraRefinement = try c.decode(Int.self, forKey: .extraRefinement)
        extraPolish = try c.decode(Int.self, forKey: .extraPolish)
        pendingNotes = try decodeNotes(c, .pendingNotes) ?? decodeNotes(c, .pendingAnnotations) ?? []
        runnerPID = try c.decodeIfPresent(Int32.self, forKey: .runnerPID)
        heartbeat = try c.decodeIfPresent(Date.self, forKey: .heartbeat)
        roundInProgress = try c.decodeIfPresent(PlannedRound.self, forKey: .roundInProgress)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(checkpoints, forKey: .checkpoints)
        try c.encode(target, forKey: .target)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(pauseDiagnosis, forKey: .pauseDiagnosis)
        try c.encode(ackedCommandSeq, forKey: .ackedCommandSeq)
        try c.encode(extraRefinement, forKey: .extraRefinement)
        try c.encode(extraPolish, forKey: .extraPolish)
        try c.encode(pendingNotes, forKey: .pendingNotes)
        try c.encodeIfPresent(runnerPID, forKey: .runnerPID)
        try c.encodeIfPresent(heartbeat, forKey: .heartbeat)
        try c.encodeIfPresent(roundInProgress, forKey: .roundInProgress)
    }

    public static let empty = Tape()

    public var head: Checkpoint? { checkpoints.last }
}

/// A control message the app sends to a detached runner via `commands.jsonl`. Custom
/// `Codable` (not synthesized) because the wire shape is a flat `{"kind", "text"?, "stage"?,
/// "by"?, "note"?, "id"?, "checkpoint"?, "markdown"?}` object rather than Swift's
/// associated-value enum encoding — the runner and app are separate processes and this is the
/// only channel between them, so the shape is fixed on purpose rather than left to whatever
/// the compiler happens to generate.
///
/// - `note` queues a `PlanNote` for the next round; `removeNote` withdraws a still-pending one.
/// - `editPlan` carries the human's WHOLE edited markdown for one checkpoint (not a patch — the
///   runner never has to reconstruct it) and the runner stores it as that checkpoint's
///   `plan.user.md`. Markdown identical to the generated plan clears the layer. Send it on a
///   save, not per keystroke: every command is a line the runner re-reads.
public enum TapeCommand: Codable, Equatable, Sendable {
    case step, nextMajor, toReview, pause, stop, extend(Stage, by: Int)
    case note(PlanNote), removeNote(UUID), editPlan(checkpoint: Int, markdown: String)

    /// The old free-text ✎ — now an unanchored comment. Its id is derived from the text (see
    /// `PlanNote.legacy`), so it equals itself however many times it is built or decoded.
    public static func annotate(_ text: String) -> TapeCommand { .note(.legacy(text)) }

    /// `annotate` is decode-only: a `commands.jsonl` written before `PlanNote` may still hold one.
    private enum Kind: String, Codable { case step, nextMajor, toReview, pause, stop, annotate, extend, note, removeNote, editPlan }
    private enum CodingKeys: String, CodingKey { case kind, text, stage, by, note, id, checkpoint, markdown }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .step: self = .step
        case .nextMajor: self = .nextMajor
        case .toReview: self = .toReview
        case .pause: self = .pause
        case .stop: self = .stop
        case .annotate: self = .annotate(try c.decode(String.self, forKey: .text))
        case .note: self = .note(try c.decode(PlanNote.self, forKey: .note))
        case .removeNote: self = .removeNote(try c.decode(UUID.self, forKey: .id))
        case .editPlan:
            self = .editPlan(checkpoint: try c.decode(Int.self, forKey: .checkpoint),
                             markdown: try c.decode(String.self, forKey: .markdown))
        case .extend:
            self = .extend(try c.decode(Stage.self, forKey: .stage), by: try c.decode(Int.self, forKey: .by))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .step: try c.encode(Kind.step, forKey: .kind)
        case .nextMajor: try c.encode(Kind.nextMajor, forKey: .kind)
        case .toReview: try c.encode(Kind.toReview, forKey: .kind)
        case .pause: try c.encode(Kind.pause, forKey: .kind)
        case .stop: try c.encode(Kind.stop, forKey: .kind)
        case .note(let note):
            try c.encode(Kind.note, forKey: .kind)
            try c.encode(note, forKey: .note)
        case .removeNote(let id):
            try c.encode(Kind.removeNote, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .editPlan(let checkpoint, let markdown):
            try c.encode(Kind.editPlan, forKey: .kind)
            try c.encode(checkpoint, forKey: .checkpoint)
            try c.encode(markdown, forKey: .markdown)
        case .extend(let stage, let by):
            try c.encode(Kind.extend, forKey: .kind)
            try c.encode(stage, forKey: .stage)
            try c.encode(by, forKey: .by)
        }
    }
}

/// One line of `commands.jsonl`. `seq` is assigned by `TapeStore.appendCommand` (max existing
/// + 1) so the runner can resume reading from `tape.ackedCommandSeq` after a restart without
/// replaying commands it already folded in.
public struct CommandEnvelope: Codable, Equatable, Sendable {
    public var seq: Int
    public var command: TapeCommand
    public init(seq: Int, command: TapeCommand) {
        self.seq = seq
        self.command = command
    }
}
