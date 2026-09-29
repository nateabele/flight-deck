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
