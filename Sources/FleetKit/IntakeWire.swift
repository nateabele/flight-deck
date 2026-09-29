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

    public init(
        etag: String, project: UUID, summary: WireIntakeSummary, intent: String,
        progress: [WireProgressPhase] = [], board: WireBoard? = nil, agents: [WireAgent] = [],
        rounds: [WireRound] = [], questions: WireQuestions? = nil, choice: WireChoice? = nil,
        failure: WireFailure? = nil, pendingNotes: Int = 0, halt: String? = nil,
        headCheckpoint: Int? = nil, servedAt: Date
    ) {
        self.etag = etag; self.project = project; self.summary = summary; self.intent = intent
        self.progress = progress; self.board = board; self.agents = agents; self.rounds = rounds
        self.questions = questions; self.choice = choice; self.failure = failure
        self.pendingNotes = pendingNotes; self.halt = halt; self.headCheckpoint = headCheckpoint
        self.servedAt = servedAt
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

    public init(
        slots: [WireSlot] = [], nowName: String, nowChip: String, clockCaption: String,
        clockSince: Date? = nil, clockText: String? = nil, stopsAt: String,
        stopSlotID: String? = nil, callingAt: String, convergence: WireConvergence? = nil,
        defaultPlay: String
    ) {
        self.slots = slots; self.nowName = nowName; self.nowChip = nowChip
        self.clockCaption = clockCaption; self.clockSince = clockSince; self.clockText = clockText
        self.stopsAt = stopsAt; self.stopSlotID = stopSlotID; self.callingAt = callingAt
        self.convergence = convergence; self.defaultPlay = defaultPlay
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

    public init(
        recommended: String? = nil, reason: String? = nil, chosen: String? = nil,
        roundsSummary: String? = nil
    ) {
        self.recommended = recommended; self.reason = reason; self.chosen = chosen
        self.roundsSummary = roundsSummary
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
