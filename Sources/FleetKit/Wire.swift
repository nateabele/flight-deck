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
    /// This project's Flight Control intakes (spec §6.1). **nil** when Flight Control is not
    /// enabled for the project — no rows and no + on the phone; `[]` when enabled with none.
    /// Optional so a snapshot from a Mac that predates it decodes (synthesized `Codable`
    /// reads an `Optional` with `decodeIfPresent`).
    public var intakes: [WireIntakeSummary]?
    /// This project's swarm (L3-S §8), or nil when it has none. Optional so a snapshot from a Mac
    /// that predates it decodes.
    public var swarm: WireSwarm?

    public init(
        id: UUID, name: String, path: String, isCollapsed: Bool = false,
        sessions: [WireSession] = [], intakes: [WireIntakeSummary]? = nil,
        swarm: WireSwarm? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isCollapsed = isCollapsed
        self.sessions = sessions
        self.intakes = intakes
        self.swarm = swarm
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
/// of the transcript — except for an agent whose transcript never holds the call, where the
/// Mac sends its words alongside this id (`WireOpenPrompt`).
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

/// The open dialog itself — its words, not only its id — sent by the Mac for an agent whose
/// transcript cannot carry it.
///
/// **The exception to `OpenPromptIdentity`'s "identity, and deliberately nothing else", and
/// it is scoped to exactly the agents that rule cannot serve.** For claude and grok the call is
/// a record in the transcript the phone already fetches, so both ends derive the dialog from the
/// same bytes and nothing but the id needs to travel. agy (gemini) never writes a WAITING step to
/// its transcript at all — the call lives only in its SQLite step store, which only the Mac can
/// read — so a phone left to derive it would find nothing, and a gemini tab blocked on a
/// permission showed "Waiting for you" with no card to answer it. The Mac sends its derivation
/// for such an agent (`AgentOpenPromptReader.transcriptCarriesOpenPrompt == false`), and only
/// for such an agent: a claude tab never carries this field, so its bytes are unchanged.
///
/// **It never replaces the veto.** The phone shows it only while `openPromptCall` names the
/// same call, and it rides the same `activityChanged` event as that id — so the supersede that
/// moves the id moves this with it, and a dialog that closes clears both on one event.
///
/// `kind` is a `String`, not an enum, for `WireSession.agent`'s reason: a kind this build has
/// never heard of decodes to a value whose `prompt` is nil — no card — rather than to a decode
/// failure that would take the whole snapshot down with it.
public struct WireOpenPrompt: Codable, Equatable, Sendable {
    public var callID: String
    /// `"permission"` or `"question"`.
    public var kind: String
    public var tool: String?
    public var summary: String?
    public var questions: [PromptQuestion]?

    public init(
        callID: String, kind: String, tool: String? = nil, summary: String? = nil,
        questions: [PromptQuestion]? = nil
    ) {
        self.callID = callID
        self.kind = kind
        self.tool = tool
        self.summary = summary
        self.questions = questions
    }

    public init(_ open: OpenPrompt) {
        switch open {
        case .permission(let id, let tool, let summary):
            self.init(callID: id, kind: "permission", tool: tool, summary: summary)
        case .question(let id, let questions):
            self.init(callID: id, kind: "question", questions: questions)
        }
    }

    /// The dialog, or nil for a kind this build cannot draw — and for a question with nothing
    /// in it, which is not a shape any reader produces and must not become an empty card.
    public var prompt: OpenPrompt? {
        switch kind {
        case "permission":
            return .permission(callID: callID, tool: tool, summary: summary)
        case "question":
            guard let questions, !questions.isEmpty else { return nil }
            return .question(callID: callID, questions)
        default:
            return nil
        }
    }
}

/// Spelled out so a newer Mac's extra keys and an older one's missing optional keys both decode:
/// only the question's text and its options are required, exactly as `init?(question:)` reads a
/// transcript's.
extension PromptQuestion: Codable {
    enum CodingKeys: String, CodingKey {
        case header, question, options, multiSelect, unanswerable
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            header: try c.decodeIfPresent(String.self, forKey: .header),
            question: try c.decode(String.self, forKey: .question),
            options: try c.decode([Option].self, forKey: .options),
            multiSelect: try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false,
            unanswerable: try c.decodeIfPresent(String.self, forKey: .unanswerable)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encode(question, forKey: .question)
        try c.encode(options, forKey: .options)
        try c.encode(multiSelect, forKey: .multiSelect)
        try c.encodeIfPresent(unanswerable, forKey: .unanswerable)
    }
}

extension PromptQuestion.Option: Codable {
    enum CodingKeys: String, CodingKey { case label, detail }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(label: try c.decode(String.self, forKey: .label),
                  detail: try c.decodeIfPresent(String.self, forKey: .detail))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(detail, forKey: .detail)
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
    /// Whether this Mac will honour `prompt.abort` for this tab.
    ///
    /// Carried rather than derived because it is a fact about the *Mac's* preferences, which
    /// the phone has no other way to see. Defaulted so a snapshot written by an older Mac
    /// decodes as off — the safe direction for a control that drives a terminal.
    public var allowsBlockedAbort: Bool = false
    /// This Mac's own verdict that `activity == "waiting"` names nothing a person can act on —
    /// `claude`'s own background-Task-subagent status reporting can leave `waitingFor` saying
    /// "input needed" with nothing actually open. Debounced on the Mac (`SessionStore`'s
    /// stuck-prompt threshold) so an ordinary race between the status file and the transcript
    /// never flips this true. `false` by default, like `hasBackgroundWork`: a snapshot from an
    /// older Mac, or any tab this Mac has not judged, keeps today's "Waiting for you" wording.
    public var answerless: Bool = false
    /// Whether this Mac drives a question's "Type something" row — `AnswerSelection.text`.
    ///
    /// A fact about the Mac's build rather than any one tab, carried per session like
    /// `allowsBlockedAbort` because that is the only Mac-to-phone channel a session's card
    /// reads. Defaulted off so an older Mac draws no field it would refuse: its decoder drops
    /// `text`, and the bare index one past the options fails its label check.
    public var acceptsTypedAnswers: Bool = false
    /// This conversation's background agents, at every depth. **`nil` means this Mac does not
    /// model them** (an older build, or a codex tab); `[]` means it does and there are none.
    /// The two must stay distinct: a phone that read an older Mac's absence as "no subagents"
    /// would hide a count (`subagentCount`) it can still see non-zero.
    public var subagents: [WireSubagent]?
    /// The subagent whose file holds the dialog `openPromptCall` names, or nil when the dialog
    /// is the conversation's own. Without it a phone pages the parent's feed for a call that
    /// lives in a subagent's file and never finds the card's tool call.
    public var openPromptAgent: String?
    /// The dialog `openPromptCall` names, in words, for an agent whose transcript cannot carry
    /// it — see `WireOpenPrompt`. Nil for every other agent and for every tab with nothing open;
    /// a client derives those itself, exactly as before.
    public var openPrompt: WireOpenPrompt?

    public init(
        id: UUID, title: String, agent: String,
        activity: String? = nil, waitingFor: String? = nil,
        subagentCount: Int = 0, isUnread: Bool = false,
        hasBackgroundWork: Bool = false,
        planGate: WirePlanGate? = nil,
        openPromptCall: OpenPromptIdentity = .unreported,
        apiError: SessionAPIError? = nil,
        allowsBlockedAbort: Bool = false,
        answerless: Bool = false,
        acceptsTypedAnswers: Bool = false,
        subagents: [WireSubagent]? = nil,
        openPromptAgent: String? = nil,
        openPrompt: WireOpenPrompt? = nil
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
        self.allowsBlockedAbort = allowsBlockedAbort
        self.answerless = answerless
        self.acceptsTypedAnswers = acceptsTypedAnswers
        self.subagents = subagents
        self.openPromptAgent = openPromptAgent
        self.openPrompt = openPrompt
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
        case hasBackgroundWork, planGate, openPromptCall, apiError, allowsBlockedAbort
        case answerless, acceptsTypedAnswers, subagents, openPromptAgent, openPrompt
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
        try c.encode(allowsBlockedAbort, forKey: .allowsBlockedAbort)
        try c.encode(answerless, forKey: .answerless)
        try c.encode(acceptsTypedAnswers, forKey: .acceptsTypedAnswers)
        // Absent, not `null`: absence is what "this Mac does not model subagents" decodes
        // from, so a codex tab must not write a key an older phone would have to ignore.
        try c.encodeIfPresent(subagents, forKey: .subagents)
        try c.encodeIfPresent(openPromptAgent, forKey: .openPromptAgent)
        // Absent, not `null`: a claude tab — every tab an older phone knows how to draw — must
        // put exactly the bytes on the wire it always has.
        try c.encodeIfPresent(openPrompt, forKey: .openPrompt)
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
        //
        // This degrades cleanly only for the FIELD, on a `WireSession` decode — a full
        // snapshot or a resync. It says nothing about `FleetEventTag.apiErrorChanged` in
        // `WireCoding.swift`: an older phone's `FleetEventTag` decoder throws on a raw value
        // it does not recognise, and that throw propagates out of `FleetEvent.init(from:)`
        // rather than landing here. See `docs/FOLLOWUPS.md`'s API-error-badge section for
        // what that costs.
        apiError = try c.decodeIfPresent(SessionAPIError.self, forKey: .apiError)
        // Absent from a Mac built before this preference existed, and from a Mac where the
        // user never turned it on — both decode as off, the safe direction for a control
        // that drives a terminal blind.
        allowsBlockedAbort = try c.decodeIfPresent(Bool.self, forKey: .allowsBlockedAbort) ?? false
        // Absent from an older Mac, and from every tab this Mac has not (yet) judged
        // answerless — both decode `false`, which is today's "Waiting for you" wording. No
        // wire version bump, matching `hasBackgroundWork`/`allowsBlockedAbort` directly above.
        answerless = try c.decodeIfPresent(Bool.self, forKey: .answerless) ?? false
        // Absent from a Mac built before typed answers — off, for the reason on the field.
        acceptsTypedAnswers = try c.decodeIfPresent(Bool.self, forKey: .acceptsTypedAnswers) ?? false
        // Absent from an older Mac, and kept nil rather than defaulted to `[]`: nil is "no
        // subagent model", which tells the phone to fall back on `subagentCount` alone.
        subagents = try c.decodeIfPresent([WireSubagent].self, forKey: .subagents)
        openPromptAgent = try c.decodeIfPresent(String.self, forKey: .openPromptAgent)
        // `try?`, not `try`: this is the one field here whose shape a newer Mac might grow, and
        // a dialog this build cannot read must cost one card, never the whole snapshot.
        openPrompt = try? c.decodeIfPresent(WireOpenPrompt.self, forKey: .openPrompt)
    }
}

/// One paired host as `flightdeck host ls` prints it: what the Mac's registry holds, plus the
/// live state of its link.
public struct WireHost: Codable, Equatable, Sendable {
    public let name: String
    /// "macOS" | "Linux", from the host's last `host.info`; nil until one has answered.
    public let platform: String?
    /// "online" | "offline" | "connecting" | "refused". A `String`, not an enum, for
    /// `WireSession.agent`'s reason: a client-side enum would throw on a state added after the
    /// client shipped.
    public let status: String
    /// Why a `refused` host turned this Mac away ("Update Flight Deck on mini"); nil otherwise.
    public let detail: String?
    /// A bare `Date`, under the same default-strategy caveat `WireConversationCatalogue`'s
    /// `sessionActivity` documents.
    public let lastSeenAt: Date?

    public init(name: String, platform: String?, status: String, detail: String?, lastSeenAt: Date?) {
        self.name = name
        self.platform = platform
        self.status = status
        self.detail = detail
        self.lastSeenAt = lastSeenAt
    }
}

/// A host's toolchain, relayed from its `host.info` reply — `flightdeck host info`.
///
/// A FleetKit copy of HostKit's `HostInfo`, plus the registry `name`, rather than that type
/// itself: FleetKit compiles for the phone and links nothing but Foundation, Network and
/// Security, and the host protocol must stay free to change without moving this wire.
public struct WireHostInfo: Codable, Equatable, Sendable {
    /// The registry's name, which is what the CLI was given. `hostName` is what the host calls
    /// itself, and the two differ once a duplicate has been renamed "mini-2".
    public let name: String
    public let hostName: String
    public let platform: String
    public let osVersion: String
    public let arch: String
    public let hostdVersion: String
    /// Empty on Linux rather than absent, for the reason `HostInfo.xcode` gives.
    public let xcode: [String]
    public let docker: String?
    public let diskFreeBytes: Int64

    public init(name: String, hostName: String, platform: String, osVersion: String, arch: String,
                hostdVersion: String, xcode: [String], docker: String?, diskFreeBytes: Int64) {
        self.name = name
        self.hostName = hostName
        self.platform = platform
        self.osVersion = osVersion
        self.arch = arch
        self.hostdVersion = hostdVersion
        self.xcode = xcode
        self.docker = docker
        self.diskFreeBytes = diskFreeBytes
    }
}
