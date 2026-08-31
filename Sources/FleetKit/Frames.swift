import Foundation

/// Why a snapshot arrived. A client that asked to resume and got a snapshot instead needs
/// to know it lost history, because that is the moment any local "since you were away"
/// affordance becomes a lie.
public enum SnapshotReason: String, Codable, Equatable, Sendable {
    /// The client asked for everything (`lastSeq == 0`).
    case initial
    /// The client asked to resume from before the ring's floor.
    case seqTooOld
}

/// What a client chose, in the one dialog a session is blocked on.
///
/// **This is the only thing this feature puts on the wire.** There is no request for the
/// question and no frame that carries it: which dialog is open, and what it says, are
/// *derived* on both ends by `OpenPrompt.find` over a transcript the phone already fetched
/// and the Mac already owns. Only the answer travels. Nothing was left out here.
///
/// **Three cases, and the absence of a fourth is a security property rather than an
/// omission.** Where claude's permission dialog offers a *"Yes, and don't ask again for Bash
/// commands in /Users/nate"* row, that row is a **durable grant** — one that outlives the tap,
/// made from a phone, from a label a fixed-width terminal wrapped. No case here names it, so
/// there is no index a client can send and no button a card can draw; and
/// `SessionStore.answerPrompt`'s `.allow` arm targets the dialog's FIRST row and nothing else.
/// A phone cannot widen its own future authority. (Captured dialogs from claude 2.1.241 show a
/// Bash permission offering only two rows, with no such option present — the property is what
/// holds when a build does offer one.) Do not add a case for it.
///
/// **`deny` is Escape, and that is the point.** The refusal path — the one a worried person
/// reaches for from a pocket, having read four words of a command — sends one key event and
/// reads nothing off the screen; the session's transcript then closes the call
/// `is_error=True "The user doesn't want to proceed with this tool use. The tool use was
/// rejected"`, which is a real denial and not a dismissal. It carries no index and no label
/// because it needs none: it cannot be wrong about which row it is on, because it is not on a
/// row. Every parsing risk in this feature therefore lives on the approval side, which is
/// where it belongs.
///
/// `option` is for `AskUserQuestion` only, where the Mac has the real labels from its own
/// transcript. `label` is a **cross-check**, never an instruction: the Mac matches its own copy
/// on screen and refuses when the client's disagrees. Nothing a client sends becomes a keystroke.
/// One chosen option, named twice.
///
/// The label travels beside the index for the reason `PromptAnswer.option` carries one: the
/// Mac checks the label against its own copy of the transcript before it counts a single
/// arrow, so a phone naming words this transcript never held is refused rather than trusted.
public struct AnswerSelection: Codable, Equatable, Sendable {
    public let index: Int
    public let label: String

    public init(index: Int, label: String) {
        self.index = index
        self.label = label
    }
}

public enum PromptAnswer: Codable, Equatable, Sendable {
    case option(index: Int, label: String)
    /// Every answer to a set of questions, at once: one array per question, in the order the
    /// questions are asked, each entry naming an option by index AND by label.
    ///
    /// **One command, not one per question.** A set is answered as a unit — the Mac walks the
    /// whole dialog and commits at the end — so a half-collected set can never be started, and
    /// one token still means one answer for the duplicate guard.
    case answers([[AnswerSelection]])
    /// A permission dialog's first row.
    case allow
    /// Escape.
    case deny

    enum CodingKeys: String, CodingKey { case answer, index, label, answers }

    /// Internal and `CaseIterable` where `FleetCommand.Op` is `private`, because this is the
    /// wire vocabulary the security property is stated in: `AnswerFrameCodingTests` counts
    /// these cases, and that assertion is the only thing that fails when a fourth is added.
    enum Tag: String, Codable, CaseIterable { case option, allow, deny, answers }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .option(let index, let label):
            try c.encode(Tag.option, forKey: .answer)
            try c.encode(index, forKey: .index)
            try c.encode(label, forKey: .label)
        case .allow:
            try c.encode(Tag.allow, forKey: .answer)
        case .deny:
            try c.encode(Tag.deny, forKey: .answer)
        case .answers(let selections):
            try c.encode(Tag.answers, forKey: .answer)
            try c.encode(selections, forKey: .answers)
        }
    }

    /// An unrecognised value throws, like `FleetCommand`'s `op` and unlike
    /// `TimelineItem.Kind`'s. Direction decides: this travels phone → Mac and is *executed*,
    /// and there is no default that is not a wrong answer — here, a keystroke in a live
    /// terminal. `TimelineAnchor.init(name:cursor:)` makes the same argument at length.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .answer) {
        case .option:
            self = .option(
                index: try c.decode(Int.self, forKey: .index),
                label: try c.decode(String.self, forKey: .label)
            )
        case .allow: self = .allow
        case .deny: self = .deny
        case .answers:
            self = .answers(try c.decode([[AnswerSelection]].self, forKey: .answers))
        }
    }
}

/// Something the client asks the Mac to do.
///
/// `ack` means *dispatched*, not done — see §4. Typing into a pty has no delivery
/// confirmation, so the observable effect always arrives separately as a northbound event.
/// One rule for both agents beats commands whose meaning depends on which agent is behind
/// them.
public enum FleetCommand: Codable, Equatable, Sendable {
    case markRead(id: UUID)
    case markUnread(id: UUID)

    /// Close tab `id`, exactly as closing it on the Mac would.
    ///
    /// Destructive and deliberately not softened: there is no "closed" state to return from,
    /// which is why the phone puts this behind a full-swipe confirmation rather than a tap.
    /// The Mac records history the same way it does for a local close, so the recovery story
    /// is the one that already exists rather than a second one invented for the phone.
    case closeSession(id: UUID)

    /// Which session this client is looking at, or `nil` when it has left one.
    ///
    /// Presence, not state: the Mac shows it beside the tab so somebody at the desk can see
    /// their phone is on that conversation. Deliberately NOT part of the fleet snapshot —
    /// it is a property of a live connection, dies with it, and putting it in replicated
    /// state would mean an event for something that cannot be replayed meaningfully.
    case viewing(session: UUID?)

    /// Rename tab `id`.
    ///
    /// The title is sanitised on the Mac, per agent, and the two agents differ: claude's
    /// rename is typed at a pty, so shell metacharacters are stripped, while codex's is
    /// JSON-RPC and only needs trimming. That difference is why no cleaning happens here —
    /// a client that pre-sanitised would either be wrong for one agent or duplicate a rule
    /// that lives on `AgentAdapter`.
    case renameSession(id: UUID, title: String)

    /// Collapse or expand project `id`'s session list.
    ///
    /// Carries the target state rather than toggling, so two clients disagreeing about what
    /// is currently collapsed cannot ping-pong: the last writer wins and both converge on the
    /// value it sent. `SessionStore.setCollapsed` already no-ops when nothing changes, so a
    /// redundant command costs an early return and no event.
    case setProjectCollapsed(id: UUID, isCollapsed: Bool)

    /// Open a new session in project `id`, with that project's defaults.
    ///
    /// No agent, account or working directory on the wire. Everything a new tab needs is
    /// already resolved on the Mac — `newSession(in:)` picks the launch account, mints the
    /// title and inherits the project's directory — and a phone that supplied any of it would
    /// be a second place those defaults live.
    ///
    /// **`agent` and `accountIndex` are both optional and both nil is today's behaviour** — the
    /// project's defaults, which is what a plain tap on `+` still sends. They arrive together,
    /// from a row of the menu `FleetRequest.newSessionOptions` answered, and `accountIndex` is a
    /// *position* rather than an id for the reason `WireNewSessionOption` gives: an account id
    /// resolves to a home directory and may not travel.
    ///
    /// A position can go stale between the fetch and the tap. The Mac re-resolves the menu and
    /// **checks the agent matches** before using the index; if it does not, it falls back to the
    /// project's default rather than opening a session as an account nobody chose. A refusal is
    /// recoverable and a silent wrong account is not.
    case newSession(project: UUID, agent: String? = nil, accountIndex: Int? = nil)

    /// Type `text` into tab `id`'s live agent and submit it.
    ///
    /// **A `cmd` and not a `req`, and `FleetRequest`'s own doc comment draws the line.** A
    /// request asks the Mac to *tell* the client something and its whole point is the data
    /// carried back; a command asks the Mac to *do* something, and `ack` means dispatched,
    /// not done — a rule §4 states because typing into a pty has no delivery confirmation.
    /// This is the operation that rule was written for. Its observable effect arrives
    /// separately, as the `.userTurn` the agent writes into its own transcript and the phone
    /// reads back over the history channel.
    ///
    /// Making it a request would mean inventing a second reply payload beside `TimelinePage`,
    /// widening `ServerFrame.page`, and retyping `FleetConnector.pending` — a change across a
    /// shipped channel to carry a boolean the transcript settles anyway. What made a request
    /// tempting is that a `cmd` told the caller nothing; that is closed instead by
    /// `FleetConnector.send(_:then:)`, which correlates the `ack` on the same `cid`.
    ///
    /// `token` is the client's own idempotency key, minted once per composed message. It is
    /// the entire answer to "what if the phone retries" — see `SessionStore.submitPrompt`,
    /// which dedupes on it and acks a repeat without queueing anything.
    case prompt(id: UUID, token: UUID, text: String)

    /// Answer the dialog that tab `id` is blocked on.
    ///
    /// **The only frame the answering feature adds, in either direction.** Nothing asks the
    /// Mac what the question is: `OpenPrompt.find` runs on both ends over the same transcript
    /// — the phone's copy from the history channel, the Mac's own tail — so the question is
    /// derived, never served. What is missing without this case is only the write path.
    ///
    /// `call` is the blocked tool call's `tool_use_id`, and it is **derived independently on
    /// both ends** rather than served by one and echoed by the other. That is what closes the
    /// race: the Mac re-derives on this path and refuses a call that is no longer the newest
    /// unanswered one (`prompt_changed`), typing nothing.
    ///
    /// It closes the harder race too, which a served-and-echoed id would not: the user approves
    /// in the terminal, claude raises the next dialog immediately, and the session **never
    /// leaves `waiting`** — so no activity change is emitted and a card that looks live is
    /// describing a dialog that is gone. A cache of "what I last served" still matches there.
    /// A re-derivation does not, because the new dialog is a different call.
    ///
    /// `token` is the client's own idempotency key, minted once per tap, for the reason
    /// `.prompt`'s is: the socket can drop between the command landing and its `ack` being
    /// read, so a retry must be free.
    case answerPrompt(id: UUID, token: UUID, call: String, answer: PromptAnswer)

    enum CodingKeys: String, CodingKey {
        case op, id, token, text, call, answer, index, label
        case isCollapsed, project, title, agent, accountIndex
    }

    private enum Op: String, Codable {
        case markRead = "session.markRead"
        case markUnread = "session.markUnread"
        case prompt = "session.prompt"
        case answerPrompt = "prompt.answer"
        case closeSession = "session.close"
        case setProjectCollapsed = "project.collapse"
        case newSession = "session.new"
        case renameSession = "session.rename"
        case viewing = "session.viewing"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .markRead(let id):
            try c.encode(Op.markRead, forKey: .op)
            try c.encode(id, forKey: .id)
        case .markUnread(let id):
            try c.encode(Op.markUnread, forKey: .op)
            try c.encode(id, forKey: .id)
        case .closeSession(let id):
            try c.encode(Op.closeSession, forKey: .op)
            try c.encode(id, forKey: .id)
        case .viewing(let session):
            try c.encode(Op.viewing, forKey: .op)
            // Absent rather than null when leaving: one short line in a dump either way.
            try c.encodeIfPresent(session, forKey: .id)
        case .renameSession(let id, let title):
            try c.encode(Op.renameSession, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
        case .setProjectCollapsed(let id, let isCollapsed):
            try c.encode(Op.setProjectCollapsed, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(isCollapsed, forKey: .isCollapsed)
        case .newSession(let project, let agent, let accountIndex):
            try c.encode(Op.newSession, forKey: .op)
            try c.encode(project, forKey: .project)
            // `encodeIfPresent`, so a plain `+` tap puts exactly the bytes on the wire it put
            // there before this feature existed — and an older Mac decoding it sees the frame
            // it has always seen.
            try c.encodeIfPresent(agent, forKey: .agent)
            try c.encodeIfPresent(accountIndex, forKey: .accountIndex)
        case .prompt(let id, let token, let text):
            try c.encode(Op.prompt, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(text, forKey: .text)
        case .answerPrompt(let id, let token, let call, let answer):
            try c.encode(Op.answerPrompt, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(call, forKey: .call)
            // Flattened into the same object rather than nested, exactly as `ClientFrame`
            // flattens a command into a frame: two keyed containers over one encoder merge
            // into a single JSON object, and one command reading as one line is what makes a
            // dump usable.
            try answer.encode(to: encoder)
        }
    }

    /// `op` is read BEFORE `id`, where the two-case version read `id` first. That mattered
    /// not at all while every case had the same one field and matters now: a prompt missing
    /// its `token` must be refused as the *prompt* it claimed to be, and an answer missing its
    /// `call` as the *answer* it claimed to be — an intent with nothing to apply it to, which
    /// accepted would act on whatever dialog happened to be up.
    ///
    /// **`text` is decoded as an ordinary `String` and is never judged here.** An unknown
    /// `op` throws — the phone → Mac direction rule `FleetRequest` states, because a command
    /// that cannot be understood cannot be executed. But a *length* or *content* refusal must
    /// not throw, and the reason is `FleetSocketServer.onUndecodable`: it salvages
    /// `t == "req"` and nothing else, deliberately, so a `cmd` this build cannot parse ends
    /// the socket. A phone that pasted a control character would lose its fleet connection,
    /// reconnect, and — with the text still sitting in its composer — be one tap from doing it
    /// again. So hostile text decodes cleanly and `SessionStore.submitPrompt` refuses it with
    /// an `err` code the phone can render into a sentence.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .markRead:
            self = .markRead(id: try c.decode(UUID.self, forKey: .id))
        case .markUnread:
            self = .markUnread(id: try c.decode(UUID.self, forKey: .id))
        case .closeSession:
            self = .closeSession(id: try c.decode(UUID.self, forKey: .id))
        case .viewing:
            self = .viewing(session: try c.decodeIfPresent(UUID.self, forKey: .id))
        case .renameSession:
            self = .renameSession(
                id: try c.decode(UUID.self, forKey: .id),
                // Never judged here, for the reason the class comment above gives about
                // `text`: a `cmd` this build cannot decode ends the socket, so a hostile or
                // over-long title must decode cleanly and be refused by the store.
                title: try c.decode(String.self, forKey: .title)
            )
        case .setProjectCollapsed:
            self = .setProjectCollapsed(
                id: try c.decode(UUID.self, forKey: .id),
                isCollapsed: try c.decode(Bool.self, forKey: .isCollapsed)
            )
        case .newSession:
            self = .newSession(
                project: try c.decode(UUID.self, forKey: .project),
                agent: try c.decodeIfPresent(String.self, forKey: .agent),
                accountIndex: try c.decodeIfPresent(Int.self, forKey: .accountIndex)
            )
        case .prompt:
            self = .prompt(
                id: try c.decode(UUID.self, forKey: .id),
                token: try c.decode(UUID.self, forKey: .token),
                text: try c.decode(String.self, forKey: .text)
            )
        case .answerPrompt:
            self = .answerPrompt(
                id: try c.decode(UUID.self, forKey: .id),
                token: try c.decode(UUID.self, forKey: .token),
                call: try c.decode(String.self, forKey: .call),
                answer: try PromptAnswer(from: decoder)
            )
        }
    }
}

/// Client → Mac.
public enum ClientFrame: Codable, Equatable, Sendable {
    /// The first frame on every socket. TLS-PSK has already established *who* this is, so
    /// this is a resume point rather than a credential. `0` means "I have nothing".
    ///
    /// `device` is what the client *calls itself* — the Mac has no other way to learn it, so
    /// without this a paired phone can only ever be listed under a placeholder. It is a
    /// claim, not a credential: identity is the slot the handshake proved, and a client is
    /// free to send nothing at all, which is what `nil` means.
    case hello(lastSeq: Int, device: String?)
    case cmd(cid: Int, FleetCommand)
    /// Ask, rather than tell. See `FleetRequest` for why this is not a `cmd`.
    case req(cid: Int, FleetRequest)

    enum CodingKeys: String, CodingKey { case t, lastSeq, device, cid }

    private enum Tag: String, Codable { case hello, cmd, req }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let lastSeq, let device):
            try c.encode(Tag.hello, forKey: .t)
            try c.encode(lastSeq, forKey: .lastSeq)
            // `encodeIfPresent`, so a client with no name to claim emits the same two-key
            // frame it always did rather than an explicit `"device":null`.
            try c.encodeIfPresent(device, forKey: .device)
        case .cmd(let cid, let command):
            try c.encode(Tag.cmd, forKey: .t)
            try c.encode(cid, forKey: .cid)
            // Flattened into the same object rather than nested under an "op" key, so a
            // command reads as one line in a dump. Two keyed containers over one encoder
            // merge into a single JSON object.
            try command.encode(to: encoder)
        case .req(let cid, let request):
            try c.encode(Tag.req, forKey: .t)
            try c.encode(cid, forKey: .cid)
            // Flattened into the same object, exactly as `cmd` flattens its command: two
            // keyed containers over one encoder merge into a single JSON object, and one
            // request reading as one line is what makes a packet dump usable.
            try request.encode(to: encoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .hello:
            // `decodeIfPresent`, not `decode`: a phone built before `device` existed sends a
            // `hello` without it, and that frame must still attach rather than throw — the
            // Mac would otherwise stop talking to every already-paired device on upgrade.
            self = .hello(lastSeq: try c.decode(Int.self, forKey: .lastSeq),
                          device: try c.decodeIfPresent(String.self, forKey: .device))
        case .cmd:
            self = .cmd(cid: try c.decode(Int.self, forKey: .cid),
                        try FleetCommand(from: decoder))
        case .req:
            self = .req(cid: try c.decode(Int.self, forKey: .cid),
                        try FleetRequest(from: decoder))
        }
    }
}

/// Mac → client. Northbound frames are sequenced; replies to commands are correlated.
public enum ServerFrame: Codable, Equatable, Sendable {
    case snapshot(seq: Int, fleet: FleetSnapshot, reason: SnapshotReason)
    case event(seq: Int, FleetEvent)
    case ack(cid: Int)
    case err(cid: Int, code: String)
    /// The reply to `ClientFrame.req`. Correlated by `cid` and deliberately **not**
    /// sequenced: a history fetch is not fleet state, and giving it a `seq` would let a
    /// client paging back through an hour of transcript move the resume point it hands the
    /// Mac on its next `hello`.
    case page(cid: Int, TimelinePage)
    /// The reply to `FleetRequest.newSessionOptions`. Unsequenced for the same reason `page`
    /// is: a menu is not fleet state, and giving it a `seq` would move the resume point a
    /// client hands back on its next `hello`.
    case newSessionOptions(cid: Int, WireNewSessionOptions)
    /// The reply to `FleetRequest.macEndpoints`. Unsequenced for the same reason `page` and
    /// `newSessionOptions` are: a list of addresses is not fleet state, and giving it a `seq`
    /// would move the resume point a client hands back on its next `hello`.
    case macEndpoints(cid: Int, [String])
    /// The reply to `FleetRequest.conversations`. Unsequenced for the same reason `page` is:
    /// see `WireConversationCatalogue`'s doc comment for why its recency field lives here
    /// and not on `FleetSnapshot`.
    case conversations(cid: Int, WireConversationCatalogue)
    /// The reply to `FleetRequest.search`. Unsequenced for the same reason `page` is: a set
    /// of search results is not fleet state.
    case searchHits(cid: Int, WireSearchHits)
    /// The reply to `FleetRequest.openConversation`: the tab it was opened into.
    case session(cid: Int, UUID)

    enum CodingKeys: String, CodingKey {
        case t, seq, fleet, reason, cid, code, page, options, endpoints
        case conversations, hits, session
    }

    /// Undotted, deliberately, and the newer three along with it — see the decoder below.
    private enum Tag: String, Codable {
        case snapshot, ack, err, page, options, endpoints, conversations, hits, session
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let seq, let fleet, let reason):
            try c.encode(Tag.snapshot, forKey: .t)
            try c.encode(seq, forKey: .seq)
            try c.encode(fleet, forKey: .fleet)
            try c.encode(reason, forKey: .reason)
        case .event(let seq, let event):
            try c.encode(seq, forKey: .seq)
            // The event supplies its own `t`; the frame adds only the sequence. One flat
            // object per change is what makes a dump readable.
            try event.encode(to: encoder)
        case .ack(let cid):
            try c.encode(Tag.ack, forKey: .t)
            try c.encode(cid, forKey: .cid)
        case .err(let cid, let code):
            try c.encode(Tag.err, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(code, forKey: .code)
        case .page(let cid, let page):
            try c.encode(Tag.page, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(page, forKey: .page)
        case .newSessionOptions(let cid, let options):
            try c.encode(Tag.options, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(options, forKey: .options)
        case .macEndpoints(let cid, let list):
            try c.encode(Tag.endpoints, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(list, forKey: .endpoints)
        case .conversations(let cid, let catalogue):
            try c.encode(Tag.conversations, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(catalogue, forKey: .conversations)
        case .searchHits(let cid, let hits):
            try c.encode(Tag.hits, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(hits, forKey: .hits)
        case .session(let cid, let session):
            try c.encode(Tag.session, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(session, forKey: .session)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Try the frame's own tags first; anything else is an event's tag, which is why
        // the two namespaces must never collide. `FleetEventTag`'s values are all dotted
        // and these nine are not, which keeps that a property rather than a promise.
        if let tag = try? c.decode(Tag.self, forKey: .t) {
            switch tag {
            case .snapshot:
                self = .snapshot(seq: try c.decode(Int.self, forKey: .seq),
                                 fleet: try c.decode(FleetSnapshot.self, forKey: .fleet),
                                 reason: try c.decode(SnapshotReason.self, forKey: .reason))
            case .ack:
                self = .ack(cid: try c.decode(Int.self, forKey: .cid))
            case .err:
                self = .err(cid: try c.decode(Int.self, forKey: .cid),
                            code: try c.decode(String.self, forKey: .code))
            case .page:
                self = .page(cid: try c.decode(Int.self, forKey: .cid),
                             try c.decode(TimelinePage.self, forKey: .page))
            case .options:
                self = .newSessionOptions(
                    cid: try c.decode(Int.self, forKey: .cid),
                    try c.decode(WireNewSessionOptions.self, forKey: .options)
                )
            case .endpoints:
                self = .macEndpoints(
                    cid: try c.decode(Int.self, forKey: .cid),
                    try c.decode([String].self, forKey: .endpoints)
                )
            case .conversations:
                self = .conversations(
                    cid: try c.decode(Int.self, forKey: .cid),
                    try c.decode(WireConversationCatalogue.self, forKey: .conversations)
                )
            case .hits:
                self = .searchHits(
                    cid: try c.decode(Int.self, forKey: .cid),
                    try c.decode(WireSearchHits.self, forKey: .hits)
                )
            case .session:
                self = .session(
                    cid: try c.decode(Int.self, forKey: .cid),
                    try c.decode(UUID.self, forKey: .session)
                )
            }
            return
        }
        self = .event(seq: try c.decode(Int.self, forKey: .seq),
                      try FleetEvent(from: decoder))
    }
}
