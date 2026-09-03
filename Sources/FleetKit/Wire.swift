import Foundation

/// The whole fleet as a client sees it: the sidebar, flattened to values.
///
/// Deliberately not `[Repo]`. `Repo` and `Session` live in the app module and carry fields
/// that exist only to derive paths on the Mac — `transcriptDirectory`, `transcriptPath`,
/// `pinnedConversationID`. Shipping them would put the Mac's filesystem layout on a phone's
/// disk for no rendering benefit, and would drag the app module across a boundary FleetKit
/// exists to hold.
public struct FleetSnapshot: Codable, Equatable, Sendable {
    public var projects: [WireProject]

    public init(projects: [WireProject] = []) {
        self.projects = projects
    }

    public static let empty = FleetSnapshot()
}

public struct WireProject: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// The project root, shown as a subtitle and used for nothing else. A client never
    /// opens it — it has no filesystem in common with the Mac.
    public var path: String
    public var isCollapsed: Bool
    public var sessions: [WireSession]

    public init(
        id: UUID, name: String, path: String, isCollapsed: Bool = false,
        sessions: [WireSession] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isCollapsed = isCollapsed
        self.sessions = sessions
    }
}

/// An open `ExitPlanMode` gate, as it goes on the wire.
///
/// **This is carried, not derived, and that is the one place this feature departs from
/// `OpenPrompt`.** Every other blocked state is re-derived on both ends from a transcript they
/// both hold, precisely so a cache cannot disagree with a screen. A plan gate cannot be: while
/// one is open, claude's registry reports `status: "busy"` — measured over 33 minutes against
/// pid 66955 on 2026-08-29 — so there is nothing in the transcript or the status file that
/// says a human is needed. Only the Mac can know, because only the Mac can read Plannotator's
/// session registry. So the fact travels.
public struct WirePlanGate: Codable, Equatable, Sendable {
    /// The `ExitPlanMode` call this gate is for. The phone sends it back with every command,
    /// and the Mac refuses anything naming a different one — the check `PromptService` makes
    /// for a dialog, made here for a gate.
    public let callID: String
    /// `"annotate"` when Plannotator is live and inline comments will pin; `"verdict"` when it
    /// is not and only a whole-plan reply is possible. A `String` rather than an enum for
    /// `WireSession.agent`'s reason: a tier added later must render degraded, not throw.
    public let tier: String
    /// The plan markdown, when the Mac read it from `GET /api/plan`. Absent in the `verdict`
    /// tier, where the phone reads it from the transcript body it already holds.
    public let plan: String?
    public let startedAt: String
    public let annotationCount: Int

    public init(callID: String, tier: String, plan: String?,
                startedAt: String, annotationCount: Int) {
        self.callID = callID
        self.tier = tier
        self.plan = plan
        self.startedAt = startedAt
        self.annotationCount = annotationCount
    }
}

/// Which dialog a session is blocked on, named by the blocked tool call's `tool_use_id`.
///
/// **Identity, and deliberately nothing else.** What the dialog *says* is still derived on
/// both ends by `OpenPrompt.find` over a transcript each already holds; that split is the
/// design and this does not touch it. What was missing is the *when*. The only thing a client
/// was ever told about a dialog was the session's `activity`, so a prompt superseded by
/// another while the session stayed `waiting` moved nothing on the wire at all — and a phone
/// went on drawing a card, and offering buttons, for a dialog its Mac had already left. Naming
/// the call makes that a wire change. The phone still reads the question out of its own copy
/// of the transcript.
///
/// **Three states, because "nobody said" and "nothing is open" are different facts.** A Mac
/// built before this field omits the key, and a client that read absence as "no dialog" would
/// hide every card it is still perfectly able to draw — a worse regression than the stale card
/// this closes, and one with no way back short of downgrading the phone. So an absent key is
/// `.unreported` and a client falls back to its own derivation, while an explicit null is this
/// Mac saying it looked and there is nothing to answer.
public enum OpenPromptIdentity: Equatable, Sendable {
    /// The peer does not report this at all — it predates the field.
    case unreported
    /// The peer looked and can name no open dialog.
    case noPrompt
    /// The blocked call's `tool_use_id`, the same string `FleetCommand.answerPrompt` carries
    /// back and the same one `PromptService` refuses an answer against.
    case call(String)

    /// The id, for a caller that only wants to compare it against one it derived itself.
    public var callID: String? {
        guard case .call(let id) = self else { return nil }
        return id
    }
}

extension KeyedEncodingContainer {
    /// `.unreported` writes no key and every other case writes one — null included — because
    /// the key's *absence* is the third state. `encodeIfPresent` over a `String?` would fold
    /// `.noPrompt` into `.unreported` and give the whole distinction away on the wire.
    mutating func encode(_ value: OpenPromptIdentity, forKey key: Key) throws {
        switch value {
        case .unreported: return
        case .noPrompt: try encodeNil(forKey: key)
        case .call(let id): try encode(id, forKey: key)
        }
    }
}

extension KeyedDecodingContainer {
    /// The mirror of the encode above, and the reason neither side may use `decodeIfPresent`:
    /// that collapses a missing key and an explicit null, which are the two cases this type
    /// exists to keep apart.
    func decode(_ type: OpenPromptIdentity.Type, forKey key: Key) throws -> OpenPromptIdentity {
        guard contains(key) else { return .unreported }
        if try decodeNil(forKey: key) { return .noPrompt }
        return .call(try decode(String.self, forKey: key))
    }
}

public struct WireSession: Codable, Equatable, Sendable, Identifiable {
    /// The tab's id, which is the only stable key a client may hold. Never the conversation
    /// id: that is not stable across a re-pin and, for codex, differs from the tab id from
    /// birth.
    public let id: UUID
    public var title: String
    /// `AgentID.rawValue`, carried as a plain `String` on purpose. A client-side enum would
    /// throw on an agent added after the client shipped, taking the entire snapshot down
    /// with it; an unrecognised string just renders without a glyph.
    public var agent: String
    /// `SessionActivity.rawValue`, or `nil` for "no agent process registered".
    /// `nil` is NOT `"idle"` — a statusless tab renders nothing where an idle one renders a
    /// dot, and collapsing the two makes every dead tab look alive.
    public var activity: String?
    /// Why the session is blocked, verbatim from the agent, when `activity == "waiting"`.
    public var waitingFor: String?
    public var subagentCount: Int
    public var isUnread: Bool
    /// A background task is running under this tab's agent. Orthogonal to `activity`, not a
    /// value of it: the Mac reports `activity: "idle"` and this together for a tab sitting at
    /// its prompt with a dev server up.
    public var hasBackgroundWork: Bool
    /// The plan gate this tab is blocked on, or `nil`. See `WirePlanGate` for why this is
    /// carried rather than derived.
    public var planGate: WirePlanGate?
    /// Which dialog this session is blocked on. See `OpenPromptIdentity` for why it is
    /// three-valued and what each state obliges a client to do; `activity == "waiting"` says
    /// only *that* something is blocked, and used to be the whole story.
    ///
    /// `.unreported` by default, because a value nobody set is nobody's assertion.
    public var openPromptCall: OpenPromptIdentity
    /// Why this session's last turn stopped, when the API refused it. Orthogonal to `activity`,
    /// like `hasBackgroundWork`: the Mac reports `activity: "idle"` and this together for a tab
    /// that died on a 529 and went quiet.
    public var apiError: SessionAPIError?

    public init(
        id: UUID, title: String, agent: String,
        activity: String? = nil, waitingFor: String? = nil,
        subagentCount: Int = 0, isUnread: Bool = false,
        hasBackgroundWork: Bool = false,
        planGate: WirePlanGate? = nil,
        openPromptCall: OpenPromptIdentity = .unreported,
        apiError: SessionAPIError? = nil
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.activity = activity
        self.waitingFor = waitingFor
        self.subagentCount = subagentCount
        self.isUnread = isUnread
        self.hasBackgroundWork = hasBackgroundWork
        self.planGate = planGate
        self.openPromptCall = openPromptCall
        self.apiError = apiError
    }

    /// Spelled out rather than synthesized, because `openPromptCall` is not `Codable` — its
    /// whole point is a state that is the *absence* of a key, which no synthesized member can
    /// express. `activity` and `waitingFor` keep `encodeIfPresent` so the bytes an older phone
    /// receives for a session with no status are the ones it has always received.
    ///
    /// **`planGate` must be listed here and written below.** It used to ride on the synthesized
    /// encoder, which gives every optional `encodeIfPresent` for free. Spelling the encoder out
    /// took that away: a member omitted from this enum is not a compile error on the encode
    /// side, it is a field that silently never reaches the wire — and the test that a gateless
    /// session encodes no key passes just as happily when the key is never encoded at all. So
    /// the gate is enumerated here and `encodeIfPresent`ed below, and
    /// `testSessionWithAGateRoundTrips` is what keeps it that way.
    enum CodingKeys: String, CodingKey {
        case id, title, agent, activity, waitingFor, subagentCount, isUnread
        case hasBackgroundWork, planGate, openPromptCall, apiError
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(agent, forKey: .agent)
        try c.encodeIfPresent(activity, forKey: .activity)
        try c.encodeIfPresent(waitingFor, forKey: .waitingFor)
        try c.encode(subagentCount, forKey: .subagentCount)
        try c.encode(isUnread, forKey: .isUnread)
        try c.encode(hasBackgroundWork, forKey: .hasBackgroundWork)
        // Absent, not `null`, exactly as the synthesized encoder used to write it — a build
        // that predates the gate must see the same bytes for a tab with none.
        try c.encodeIfPresent(planGate, forKey: .planGate)
        try c.encode(openPromptCall, forKey: .openPromptCall)
        // Absent, not `null`, for the same reason `planGate` is: a build that predates this
        // field must see exactly the bytes it has always seen for a session that has no error.
        try c.encodeIfPresent(apiError, forKey: .apiError)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        agent = try c.decode(String.self, forKey: .agent)
        let decodedActivity = try c.decodeIfPresent(String.self, forKey: .activity)
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
        subagentCount = try c.decode(Int.self, forKey: .subagentCount)
        isUnread = try c.decode(Bool.self, forKey: .isUnread)
        // Absent from an older Mac's snapshot, and that is a meaningful value, not an error.
        let decodedBackgroundWork = try c.decodeIfPresent(
            Bool.self, forKey: .hasBackgroundWork
        ) ?? false
        // Absent from an older Mac too, and here the absence is kept rather than defaulted
        // away: `.unreported` is what tells this client to go on trusting its own derivation.
        openPromptCall = try c.decode(OpenPromptIdentity.self, forKey: .openPromptCall)
        // The wire version was deliberately not bumped for the `hasBackgroundWork` split, so
        // an older Mac can still send the pre-decomposition `"shell"` string here. That is
        // this skew's other direction from the `hasBackgroundWork` key being absent above:
        // rather than an error state, `"shell"` decodes to exactly what a newer Mac would
        // have sent for the same fact — `activity: "idle"` plus the flag — so an old Mac and
        // a new one render identically on this build.
        if decodedActivity == "shell" {
            activity = "idle"
            hasBackgroundWork = true
        } else {
            activity = decodedActivity
            hasBackgroundWork = decodedBackgroundWork
        }
        // Absent from a Mac built before this feature, and from any tab with no gate open —
        // both decode as no gate, not as an error. See `WirePlanGate` for why the fact is
        // carried at all rather than derived like everything else here.
        planGate = try c.decodeIfPresent(WirePlanGate.self, forKey: .planGate)
        // Absent from an older Mac, and from every healthy session — both decode as "no error",
        // not as a failure. Same contract as `hasBackgroundWork` above, and the reason
        // `FleetKitVersion.wire` is deliberately not bumped for this field either.
        apiError = try c.decodeIfPresent(SessionAPIError.self, forKey: .apiError)
    }
}
