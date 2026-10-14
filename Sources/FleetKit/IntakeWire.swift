import Foundation

/// One Flight Control intake as the Sessions list shows it — the coarse, sequenced part of the
/// phone's view of Flight Control (spec §6.1).
///
/// **Coarse on purpose.** Nothing here moves at agent-activity rate: it changes on a state
/// transition, a round starting or landing, an agent finishing, pause/resume, and release. The
/// live detail is `WireIntakeDetail`, fetched by request while a screen is open — putting it
/// here would record an event every two seconds per agent into the replay ring.
///
/// State-like values are `String`s, never enums: a state added on the Mac later must render
/// degraded on an older phone, not throw and end its socket.
public struct WireIntakeSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// `IntakeTitle.lead`, computed on the Mac so both ends cut the intent identically.
    public var title: String
    /// `IntakeState` raw value.
    public var state: String
    /// The Mac's own rule (`IntakeService.needsAttention(_:)`), never re-derived on the phone.
    public var needsAttention: Bool
    /// `Preset` raw value (`bead` reads "Single task" on screen).
    public var preset: String?
    /// The board's NOW name — "Refine 2", "Clarify 1", "Triage", "Review".
    public var now: String?
    /// `RunnerStatus` raw value while shaping.
    public var runStatus: String?
    /// When the current in-the-air or paused-for interval started (Mac clock).
    public var clockSince: Date?
    /// The round in flight only.
    public var agentsDone: Int?
    public var agentsTotal: Int?
    /// `needsAnswers` only: the open round's question count.
    public var questionCount: Int?
    /// `released`/`partiallyReleased` only.
    public var releasedTaskCount: Int?
    /// Orders "newest first" within a group on the phone.
    public var createdAt: Date

    public init(
        id: UUID, title: String, state: String, needsAttention: Bool, preset: String? = nil,
        now: String? = nil, runStatus: String? = nil, clockSince: Date? = nil,
        agentsDone: Int? = nil, agentsTotal: Int? = nil, questionCount: Int? = nil,
        releasedTaskCount: Int? = nil, createdAt: Date
    ) {
        self.id = id; self.title = title; self.state = state; self.needsAttention = needsAttention
        self.preset = preset; self.now = now; self.runStatus = runStatus; self.clockSince = clockSince
        self.agentsDone = agentsDone; self.agentsTotal = agentsTotal
        self.questionCount = questionCount; self.releasedTaskCount = releasedTaskCount
        self.createdAt = createdAt
    }
}

/// Everything the intake screen shows, fetched by `FleetRequest.intakeDetail` and polled while
/// the screen is open (spec §6.2). **Nothing here depends on the Mac's clock** except
/// `servedAt`: running clocks travel as start DATES, so the encoded detail — and its `etag` —
/// stays byte-identical while nothing happens, and an idle poll costs a few dozen bytes.
public struct WireIntakeDetail: Codable, Equatable, Sendable {
    public var etag: String
    public var project: UUID
    public var summary: WireIntakeSummary
    public var intent: String
    public var progress: [WireProgressPhase]
    public var board: WireBoard?
    public var agents: [WireAgent]
    public var rounds: [WireRound]
    public var questions: WireQuestions?
    public var choice: WireChoice?
    public var failure: WireFailure?
    public var pendingNotes: Int
    public var halt: String?
    public var headCheckpoint: Int?
    public var servedAt: Date
    /// true from a Mac that accepts `intake.*` commands — the phone's ONLY licence to send them;
    /// an older Mac drops the socket on an unknown command. nil from a Phase-1 Mac.
    public var steer: Bool?
    /// true from a Mac that accepts `intake.choose` — the phone's licence to offer the fidelity
    /// chooser, separate from `steer` because a Mac that steers but predates this would drop
    /// the socket on the unknown op. nil from such a Mac, and the phone says to choose on the Mac.
    public var choose: Bool?
    /// true from a Mac that accepts `intake.setNoteKind` — the phone's licence to retype a note
    /// from its row. nil from an older Mac, which would drop the socket on the unknown op; the
    /// phone then offers nothing it can't send.
    public var noteKind: Bool?
    /// The round configuration the intake is actually running (a customized one included), once
    /// a fidelity is chosen; nil before that, and from a Mac that predates the phone inspector.
    public var roundConfig: WireRoundConfig?

    public init(
        etag: String, project: UUID, summary: WireIntakeSummary, intent: String,
        progress: [WireProgressPhase] = [], board: WireBoard? = nil, agents: [WireAgent] = [],
        rounds: [WireRound] = [], questions: WireQuestions? = nil, choice: WireChoice? = nil,
        failure: WireFailure? = nil, pendingNotes: Int = 0, halt: String? = nil,
        headCheckpoint: Int? = nil, servedAt: Date, steer: Bool? = nil, choose: Bool? = nil, noteKind: Bool? = nil,
        roundConfig: WireRoundConfig? = nil
    ) {
        self.etag = etag; self.project = project; self.summary = summary; self.intent = intent
        self.progress = progress; self.board = board; self.agents = agents; self.rounds = rounds
        self.questions = questions; self.choice = choice; self.failure = failure
        self.pendingNotes = pendingNotes; self.halt = halt; self.headCheckpoint = headCheckpoint
        self.servedAt = servedAt; self.steer = steer; self.choose = choose; self.noteKind = noteKind
        self.roundConfig = roundConfig
    }
}

/// One phase line of the pre-shaping progress list (label plus its timing/detail text).
public struct WireProgressPhase: Codable, Equatable, Sendable {
    public var label: String
    public var detail: String

    public init(label: String, detail: String) {
        self.label = label; self.detail = detail
    }
}

/// The route board, mirroring the Mac's `BoardModel` as plain values.
public struct WireBoard: Codable, Equatable, Sendable {
    public var slots: [WireSlot]
    public var nowName: String
    public var nowChip: String
    public var clockCaption: String
    public var clockSince: Date?
    public var clockText: String?
    public var stopsAt: String
    public var stopSlotID: String?
    public var callingAt: String
    public var convergence: WireConvergence?
    public var defaultPlay: String
    /// The transport keys this tape allows right now; nil from a Phase-1 Mac.
    public var controls: WireControls?

    public init(
        slots: [WireSlot] = [], nowName: String, nowChip: String, clockCaption: String,
        clockSince: Date? = nil, clockText: String? = nil, stopsAt: String,
        stopSlotID: String? = nil, callingAt: String, convergence: WireConvergence? = nil,
        defaultPlay: String, controls: WireControls? = nil
    ) {
        self.slots = slots; self.nowName = nowName; self.nowChip = nowChip
        self.clockCaption = clockCaption; self.clockSince = clockSince; self.clockText = clockText
        self.stopsAt = stopsAt; self.stopSlotID = stopSlotID; self.callingAt = callingAt
        self.convergence = convergence; self.defaultPlay = defaultPlay; self.controls = controls
    }
}

/// The Mac's `TransportRules`, as strings; nil from a Phase-1 Mac. `enabled` names the keys the
/// Mac would accept now (`step`, `nextMajor`, `toReview`, `pause`, `stop`, `extend`, `trim`), so
/// the phone never offers one it would refuse; an unknown name from a newer Mac is ignored.
/// `extendStage`/`trimStage` are the stage + and − act on; `cycleName` and `cyclePlanned` name
/// that cycle and its planned round count for the ± label.
public struct WireControls: Codable, Equatable, Sendable {
    public var enabled: [String]
    public var extendStage: String?
    public var trimStage: String?
    public var cycleName: String?
    public var cyclePlanned: Int?

    public init(enabled: [String], extendStage: String? = nil, trimStage: String? = nil,
                cycleName: String? = nil, cyclePlanned: Int? = nil) {
        self.enabled = enabled; self.extendStage = extendStage; self.trimStage = trimStage
        self.cycleName = cycleName; self.cyclePlanned = cyclePlanned
    }
}

/// One stop on the board. `state` is done|live|future|failed, kept a string so a newer Mac's
/// state renders degraded on an older phone.
public struct WireSlot: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var code: String
    public var state: String
    public var major: Bool
    public var group: String?
    public var checkpoint: Int?
    public var duration: TimeInterval?
    public var flagged: Bool

    public init(
        id: String, name: String, code: String, state: String, major: Bool = false,
        group: String? = nil, checkpoint: Int? = nil, duration: TimeInterval? = nil,
        flagged: Bool = false
    ) {
        self.id = id; self.name = name; self.code = code; self.state = state; self.major = major
        self.group = group; self.checkpoint = checkpoint; self.duration = duration
        self.flagged = flagged
    }
}

/// The board's convergence readout: a word, its tone, and the sparkline of change counts.
public struct WireConvergence: Codable, Equatable, Sendable {
    public var word: String
    public var amber: Bool
    public var spark: [Double]

    public init(word: String, amber: Bool = false, spark: [Double] = []) {
        self.word = word; self.amber = amber; self.spark = spark
    }
}

/// One agent row — `SeatRowModel` built on the Mac at a fixed instant. `glyph` is
/// queued|running|done|failed|fallback|needsYou.
public struct WireAgent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var glyph: String
    public var role: String
    public var identity: String
    public var headline: String?
    public var action: String?
    public var steps: String?
    public var contextFraction: Double?
    public var footprint: [WireFootprint]
    public var result: String?
    public var cost: Double?
    public var startedAt: Date?
    public var lastEventAt: Date?
    public var rateLimitedAt: Date?
    public var duration: TimeInterval?
    public var fallback: String?
    public var failure: String?

    public init(
        id: String, glyph: String, role: String, identity: String, headline: String? = nil,
        action: String? = nil, steps: String? = nil, contextFraction: Double? = nil,
        footprint: [WireFootprint] = [], result: String? = nil, cost: Double? = nil,
        startedAt: Date? = nil, lastEventAt: Date? = nil, rateLimitedAt: Date? = nil,
        duration: TimeInterval? = nil, fallback: String? = nil, failure: String? = nil
    ) {
        self.id = id; self.glyph = glyph; self.role = role; self.identity = identity
        self.headline = headline; self.action = action; self.steps = steps
        self.contextFraction = contextFraction; self.footprint = footprint; self.result = result
        self.cost = cost; self.startedAt = startedAt; self.lastEventAt = lastEventAt
        self.rateLimitedAt = rateLimitedAt; self.duration = duration; self.fallback = fallback
        self.failure = failure
    }
}

/// How many files an agent touched under one top-level directory.
public struct WireFootprint: Codable, Equatable, Sendable {
    public var dir: String
    public var count: Int

    public init(dir: String, count: Int) {
        self.dir = dir; self.count = count
    }
}

/// One landed round — the Mac's `Checkpoint` plus its `RoundRecord`. `outcome` is
/// ok|fallback|failed.
public struct WireRound: Codable, Equatable, Sendable {
    public var checkpoint: Int
    public var name: String
    public var code: String
    public var stage: String
    public var startedAt: Date?
    public var landedAt: Date
    public var outcome: String
    public var changeCount: Int?
    public var linesAdded: Int
    public var linesRemoved: Int
    public var verdicts: WireVerdicts?
    public var note: String?
    public var sectionsChanged: [String]
    public var agents: [WireRoundAgent]
    public var notesConsumed: [WireNote]

    public init(
        checkpoint: Int, name: String, code: String, stage: String, startedAt: Date? = nil,
        landedAt: Date, outcome: String, changeCount: Int? = nil, linesAdded: Int = 0,
        linesRemoved: Int = 0, verdicts: WireVerdicts? = nil, note: String? = nil,
        sectionsChanged: [String] = [], agents: [WireRoundAgent] = [],
        notesConsumed: [WireNote] = []
    ) {
        self.checkpoint = checkpoint; self.name = name; self.code = code; self.stage = stage
        self.startedAt = startedAt; self.landedAt = landedAt; self.outcome = outcome
        self.changeCount = changeCount; self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved; self.verdicts = verdicts; self.note = note
        self.sectionsChanged = sectionsChanged; self.agents = agents
        self.notesConsumed = notesConsumed
    }
}

/// How the reviewer's suggestions were received in a round.
public struct WireVerdicts: Codable, Equatable, Sendable {
    public var agreed: Int
    public var somewhat: Int
    public var declined: Int

    public init(agreed: Int, somewhat: Int, declined: Int) {
        self.agreed = agreed; self.somewhat = somewhat; self.declined = declined
    }
}

/// One agent's line in a landed round. `status` is ok|substituted|failed.
public struct WireRoundAgent: Codable, Equatable, Sendable {
    public var role: String
    public var ran: String
    public var status: String
    public var detail: String?

    public init(role: String, ran: String, status: String, detail: String? = nil) {
        self.role = role; self.ran = ran; self.status = status; self.detail = detail
    }
}

/// A note on the plan — the Mac's `PlanNote`; `kind` is the `NoteKind` raw value.
public struct WireNote: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: String
    public var text: String
    public var quote: String?
    public var section: String?
    public var consumed: Bool
    public var blockIndex: Int?

    public init(
        id: UUID, kind: String, text: String, quote: String? = nil, section: String? = nil,
        consumed: Bool = false, blockIndex: Int? = nil
    ) {
        self.id = id; self.kind = kind; self.text = text; self.quote = quote
        self.section = section; self.consumed = consumed; self.blockIndex = blockIndex
    }
}

/// The clarify round's questions: `open` is nil when none are waiting on the user.
public struct WireQuestions: Codable, Equatable, Sendable {
    public var open: [String]?
    public var answered: [WireExchange]

    public init(open: [String]? = nil, answered: [WireExchange] = []) {
        self.open = open; self.answered = answered
    }
}

/// One answered round of questions, index-aligned with its answers.
public struct WireExchange: Codable, Equatable, Sendable {
    public var questions: [String]
    public var answers: [String]

    public init(questions: [String], answers: [String]) {
        self.questions = questions; self.answers = answers
    }
}

/// The preset choice screen: what the Mac recommends and what was chosen.
public struct WireChoice: Codable, Equatable, Sendable {
    public var recommended: String?
    public var reason: String?
    public var chosen: String?
    public var roundsSummary: String?
    /// What each fidelity would seat, in the order the Mac lists them; nil from a Mac that
    /// predates the phone chooser, which the phone reads as "choose on the Mac".
    public var presets: [WirePresetOption]?

    public init(
        recommended: String? = nil, reason: String? = nil, chosen: String? = nil,
        roundsSummary: String? = nil, presets: [WirePresetOption]? = nil
    ) {
        self.recommended = recommended; self.reason = reason; self.chosen = chosen
        self.roundsSummary = roundsSummary; self.presets = presets
    }
}

/// One fidelity on the chooser. `preset` is the `Preset` raw value, kept a string so a fidelity
/// added on the Mac later renders degraded on an older phone. `config` is what the Mac would
/// seat for it right now (`PresetExpansion`); nil for the single-task fidelity, which runs no
/// planning rounds, and for a machine with no agent able to run them.
public struct WirePresetOption: Codable, Equatable, Sendable {
    public var preset: String
    public var config: WireRoundConfig?

    public init(preset: String, config: WireRoundConfig? = nil) {
        self.preset = preset; self.config = config
    }
}

/// An agent, model and effort — the Mac's `ModelChoice`. `agent` is the `AgentID` raw value and
/// `agentName` its display name, so the phone never needs the Mac's agent table.
public struct WireModelChoice: Codable, Equatable, Sendable {
    public var agent: String
    public var agentName: String?
    public var model: String
    public var effort: String
    /// The model's name as the Mac shows it ("Opus 5.5"), so the phone never shows an id. nil from
    /// a Mac that predates it: the phone then falls back to `model`.
    public var modelName: String?
    /// The name of the account or pool this role bills when it holds its own; nil bills the
    /// project's assignment, which the phone does not name.
    public var account: String?

    public init(agent: String, agentName: String? = nil, model: String, effort: String,
                modelName: String? = nil, account: String? = nil) {
        self.agent = agent; self.agentName = agentName; self.model = model; self.effort = effort
        self.modelName = modelName; self.account = account
    }
}

/// One agent in a round configuration — the Mac's `Slot`. `persona` is the `DrafterPersona` raw
/// value for a drafter, synthesizer or reviewer, `fallback` the availability retry.
public struct WireSeat: Codable, Equatable, Sendable {
    public var choice: WireModelChoice
    public var persona: String?
    public var fallback: WireModelChoice?

    public init(choice: WireModelChoice, persona: String? = nil, fallback: WireModelChoice? = nil) {
        self.choice = choice; self.persona = persona; self.fallback = fallback
    }
}

/// The Mac's `RoundConfig` as plain values, for the phone's read-only inspector. `crossCheck` is
/// the `CrossCheckPolicy` raw value and `defaultPlay` the `PlayMode` one. The phone shows an
/// optional agent only when present, so a stage with no agent (Sketch has no polisher) simply
/// has no row.
public struct WireRoundConfig: Codable, Equatable, Sendable {
    public var drafters: [WireSeat]
    public var synthesizer: WireSeat?
    public var reviewer: WireSeat?
    public var crossReviewer: WireSeat?
    public var crossCheck: String?
    public var integrator: WireSeat
    public var encoder: WireSeat
    public var polisher: WireSeat?
    public var refinementCap: Int
    public var polishCap: Int
    public var freshEyesAndDedup: Bool
    public var defaultPlay: String
    public var customized: Bool
    /// The agents a role takes in turn, round after round (the Mac's `RoundConfig.reviewers`,
    /// `integrators`, `polishers`), in order. nil or empty: the role has the one agent above,
    /// which is also the first entry here, so a phone that predates rotations still shows a
    /// sensible agent and ignores these.
    public var reviewers: [WireSeat]?
    public var integrators: [WireSeat]?
    public var polishers: [WireSeat]?

    public init(
        drafters: [WireSeat], synthesizer: WireSeat? = nil, reviewer: WireSeat? = nil,
        crossReviewer: WireSeat? = nil, crossCheck: String? = nil, integrator: WireSeat,
        encoder: WireSeat, polisher: WireSeat? = nil, refinementCap: Int, polishCap: Int,
        freshEyesAndDedup: Bool, defaultPlay: String, customized: Bool,
        reviewers: [WireSeat]? = nil, integrators: [WireSeat]? = nil, polishers: [WireSeat]? = nil
    ) {
        self.drafters = drafters; self.synthesizer = synthesizer; self.reviewer = reviewer
        self.crossReviewer = crossReviewer; self.crossCheck = crossCheck
        self.integrator = integrator; self.encoder = encoder; self.polisher = polisher
        self.refinementCap = refinementCap; self.polishCap = polishCap
        self.freshEyesAndDedup = freshEyesAndDedup; self.defaultPlay = defaultPlay
        self.customized = customized
        self.reviewers = reviewers; self.integrators = integrators; self.polishers = polishers
    }
}

/// Why an intake failed, with the tail of the agent's output when there is one.
public struct WireFailure: Codable, Equatable, Sendable {
    public var reason: String
    public var output: String?

    public init(reason: String, output: String? = nil) {
        self.reason = reason; self.output = output
    }
}

/// The plan document at one checkpoint. `added`/`removed` are a block-level diff against the
/// parent checkpoint, nil when not asked for.
public struct WireIntakePlan: Codable, Equatable, Sendable {
    public var checkpoint: Int
    public var roundName: String
    public var editsVersion: String
    public var markdown: String
    public var outline: [WireSection]
    public var notes: [WireNote]
    public var added: [Int]?
    public var removed: [WireRemovedBlock]?

    public init(
        checkpoint: Int, roundName: String, editsVersion: String, markdown: String,
        outline: [WireSection] = [], notes: [WireNote] = [], added: [Int]? = nil,
        removed: [WireRemovedBlock]? = nil
    ) {
        self.checkpoint = checkpoint; self.roundName = roundName; self.editsVersion = editsVersion
        self.markdown = markdown; self.outline = outline; self.notes = notes
        self.added = added; self.removed = removed
    }
}

/// One heading in the plan's outline, with per-round churn and whether it is still moving.
public struct WireSection: Codable, Equatable, Sendable {
    public var heading: String
    public var level: Int
    public var blockIndex: Int
    public var churn: [Int]
    public var diverging: Bool
    public var settledSince: String?

    public init(
        heading: String, level: Int, blockIndex: Int, churn: [Int] = [], diverging: Bool = false,
        settledSince: String? = nil
    ) {
        self.heading = heading; self.level = level; self.blockIndex = blockIndex
        self.churn = churn; self.diverging = diverging; self.settledSince = settledSince
    }
}

/// A block present in the parent checkpoint but gone now; `after` is the block it followed.
public struct WireRemovedBlock: Codable, Equatable, Sendable {
    public var after: Int?
    public var text: String

    public init(after: Int? = nil, text: String) {
        self.after = after; self.text = text
    }
}
