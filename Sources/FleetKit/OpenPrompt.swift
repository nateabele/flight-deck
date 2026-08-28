import Foundation

/// An `AskUserQuestion`'s input, read.
///
/// **Not a wire type, and that is the design.** An earlier draft of this feature transmitted a
/// `PendingPrompt` over a new request/response pair. It was deleted: the payload is the tool
/// call's own input, the history channel already fetches it, and `ClaudeTimelineMapper` already
/// carries it in `TimelineItem.Body.text`. So this is a *derivation* both ends run over data
/// they already hold — which is also why it lives in `FleetKit` and not in either app. The Mac
/// and the phone must not run two versions of this rule.
public struct PromptQuestion: Equatable, Hashable, Sendable {
    public struct Option: Equatable, Hashable, Sendable {
        public var label: String
        /// The option's `description`. Frequently a line and a half, and the only thing on the
        /// card that says what the option MEANS.
        public var detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    /// `AskUserQuestion`'s `header` — a short label above the question.
    public var header: String?
    public var question: String
    public var options: [Option]
    /// Why this cannot be answered from a phone, or `nil` when it can.
    ///
    /// A sentence rather than a code, because the reasons are facts about what the *Mac* can
    /// drive: this build has never observed the key protocol for a multi-select list, and a
    /// call carrying two questions shows them in sequence so answering the first would leave
    /// the second up with the reader believing they were done.
    public var unanswerable: String?

    public init(
        header: String? = nil, question: String, options: [Option], unanswerable: String? = nil
    ) {
        self.header = header
        self.question = question
        self.options = options
        self.unanswerable = unanswerable
    }

    public var isAnswerable: Bool { unanswerable == nil && !options.isEmpty }

    public static let multiSelectReason =
        "This question takes more than one answer. Answer it on your Mac."
    public static let multiQuestionReason =
        "This is several questions at once. Answer them on your Mac."

    /// Reads an `AskUserQuestion` tool input.
    ///
    /// `toolInput` is the input object's JSON text — on the phone that is
    /// `TimelineItem.Body.text` for a `.prompt` row, and on the Mac it is the record's own
    /// `input` re-serialized. One parser, two entry points, by construction; the two byte
    /// sequences differ (the phone's is pretty-printed and key-sorted by `ToolInputSummary`)
    /// and must read the same.
    ///
    /// **Nil rather than a partial read.** `JSONValue.parse` is strict and refuses trailing
    /// content, which is what makes a body cut at `TimelineLimits.maxItemBytes` — the ordinary
    /// state of a large tool input, per `TimelineItem.Body.text` — return nothing here instead
    /// of a question missing its last two options. Three of four choices is worse than none.
    ///
    /// The shape, from `Fixtures/Claude/question-single.captured.jsonl` (claude 2.1.241):
    /// `{"questions":[{"question":…,"header":…,"multiSelect":false,
    ///   "options":[{"label":…,"description":…}]}]}`
    public init?(toolInput: String) {
        guard let root = JSONValue.parse(toolInput),
              case .array(let questions)? = root.member("questions"),
              let first = questions.first,
              case .string(let text)? = first.member("question"),
              case .array(let rawOptions)? = first.member("options")
        else { return nil }

        let options: [Option] = rawOptions.compactMap { option in
            // An option with no label cannot be drawn, and cannot be found on the Mac's screen
            // either — the answer path locates the row BY its label — so carrying it would put
            // an index in the list that no keystroke can reach.
            guard case .string(let label)? = option.member("label"), !label.isEmpty
            else { return nil }
            if case .string(let detail)? = option.member("description"), !detail.isEmpty {
                return Option(label: label, detail: detail)
            }
            return Option(label: label)
        }
        // A question with nothing to pick is not one this feature can show, and is not a shape
        // the tool produces. Refusing keeps a malformed record off the screen.
        guard !options.isEmpty else { return nil }

        var header: String?
        if case .string(let raw)? = first.member("header"), !raw.isEmpty { header = raw }

        // **Only this question's own answerability**, never the set's. Whether there are
        // several questions is a fact about the PROMPT, and it used to be recorded here — on
        // question one — which is why a set of three showed its first question wearing a
        // reason that belonged to all of them, and hid the other two entirely. `all(toolInput:)`
        // returns the set; what the card can do with it is the card's judgement.
        var unanswerable: String?
        if case .bool(true)? = first.member("multiSelect") { unanswerable = Self.multiSelectReason }

        self.init(header: header, question: text, options: options, unanswerable: unanswerable)
    }

    /// Every question in one `AskUserQuestion` input, in the order it asks them.
    ///
    /// **Reading only the first was the bug.** 16% of real `AskUserQuestion` calls carry more
    /// than one question (measured over 374 records), and for every one of them the phone drew
    /// question one, read-only, and simply did not draw the rest — so a reader could not even
    /// see what they were being asked to go and answer somewhere else.
    ///
    /// Empty rather than nil for a body that is not this shape, so the one caller can treat
    /// "not a question" and "no questions" as the same thing, which they are.
    public static func all(toolInput: String) -> [PromptQuestion] {
        guard let root = JSONValue.parse(toolInput),
              case .array(let questions)? = root.member("questions")
        else { return [] }
        return questions.compactMap { PromptQuestion(question: $0) }
    }

    /// One element of the `questions` array. Split out of `init?(toolInput:)` so the set and
    /// the single case cannot read a question two different ways.
    init?(question: JSONValue) {
        guard case .string(let text)? = question.member("question"),
              case .array(let rawOptions)? = question.member("options")
        else { return nil }
        let options: [Option] = rawOptions.compactMap { option in
            guard case .string(let label)? = option.member("label"), !label.isEmpty
            else { return nil }
            if case .string(let detail)? = option.member("description"), !detail.isEmpty {
                return Option(label: label, detail: detail)
            }
            return Option(label: label)
        }
        guard !options.isEmpty else { return nil }
        var header: String?
        if case .string(let raw)? = question.member("header"), !raw.isEmpty { header = raw }
        var unanswerable: String?
        if case .bool(true)? = question.member("multiSelect") {
            unanswerable = Self.multiSelectReason
        }
        self.init(header: header, question: text, options: options, unanswerable: unanswerable)
    }
}

/// What a session is blocked on, derived rather than transmitted.
public enum OpenPrompt: Equatable, Sendable {
    /// An `AskUserQuestion`. Structured, exact, with descriptions.
    /// Every question the call asks, in order. A set of one is the ordinary case; a set of
    /// several is 16% of them, and used to be shown as its first question alone.
    case question(callID: String, [PromptQuestion])
    /// Any other tool awaiting approval. **There is no structured payload for this case and
    /// there is nowhere to get one**: the `tool_use` record is byte-identical to one for a
    /// tool that is merely running, and the dialog's own wording ("Yes, and don't ask again
    /// for Bash commands in …") is assembled in the TUI at display time from the live
    /// permission rule set. What is available is the call itself, which is *more* than the
    /// terminal shows — the whole input, not a one-line summary — and the reason string
    /// `WireSession.waitingFor` already carries.
    case permission(callID: String, tool: String?, summary: String?)

    public var callID: String {
        switch self {
        case .question(let id, _), .permission(let id, _, _): return id
        }
    }

    /// The one open-call rule. **Run identically on the Mac and on the phone, over the same
    /// transcript, and never sent between them** — which is what closes the race where a user
    /// answers in the terminal, or where claude answers one dialog and raises the next without
    /// the session ever leaving `waiting`. A cache of "what was last served" would still match
    /// in that second case; a re-derivation cannot.
    ///
    /// Three conditions, and all are necessary:
    ///
    /// - **An agent whose dialogs a Mac can drive.** Everything this type produces is an
    ///   *offer*: Allow and Deny, or an option list, drawn from claude's dialog grammar and
    ///   answered by keystrokes at claude's screen. A card for an agent nothing can answer is
    ///   an offer that cannot be honoured — the tap comes back `unsupported_agent` — and
    ///   drawing one is worse than drawing none, so an agent with no known dialog is blocked
    ///   on nothing as far as this type is concerned.
    ///
    ///   A `String` compared against a literal, exactly as `WireSession.subagentSummary` is
    ///   and for the same reason: `agent` is a bare `String` so an agent this build has never
    ///   heard of degrades to "renders without one" rather than taking the screen down, and
    ///   inventing a dialog for it would be the same mistake as inventing a count. **Add an
    ///   agent to this list when — and only when — something can actually answer for it.**
    ///
    ///   This is presentation only. The refusal that protects a terminal is
    ///   `SessionStore.answerPrompt`'s, over on the Mac, and it is not weakened by anything
    ///   decided here. A codex approval list is closer to `ChoiceDialog`'s model than claude's
    ///   own is, so this is a capability that may well be earned; what it needs first is a
    ///   Mac that can drive it, not a card that says it can.
    /// - **`activity == "waiting"`.** An unanswered call on an idle or busy session is a call
    ///   whose result has not been read yet, which is the ordinary state of any feed a beat
    ///   behind the file.
    /// - **No `tool_result` carries this `callID`.** The same pairing
    ///   `SessionTimelineScreen.entries(from:)` already does to fold output into a command.
    ///
    /// For `AskUserQuestion` the pair is exact, because that tool's *execution is the human
    /// answering*. For every other tool it means "approving or running", and `waiting` is what
    /// separates the two.
    ///
    /// `agent` is required rather than defaulted, so no caller can derive an open prompt
    /// without saying whose it is.
    public static func find(
        in items: [TimelineItem], agent: String?, activity: String?
    ) -> OpenPrompt? {
        guard agent == "claude" else { return nil }
        guard activity == "waiting" else { return nil }

        // Built from the WHOLE feed first. A merged feed can hold a result above its own call
        // when a page boundary landed between them, so "what follows this call" is not a safe
        // question to ask.
        var answered: Set<String> = []
        for item in items where item.kind == .toolResult {
            if let id = item.body.callID { answered.insert(id) }
        }

        for item in items.reversed() {
            guard let id = item.body.callID, !answered.contains(id) else { continue }
            switch item.kind {
            case .prompt:
                // A body that will not parse is NOT downgraded to a permission card: that
                // would draw Allow/Deny for a dialog whose first row is "Rust". Nor does it
                // fall through to an older call — that is not what the terminal is showing.
                let questions = PromptQuestion.all(toolInput: item.body.text)
                guard !questions.isEmpty else { return nil }
                return .question(callID: id, questions)
            case .toolCall:
                return .permission(callID: id, tool: item.body.tool, summary: item.body.summary)
            default:
                // A kind this build cannot name — `.unknown`, decoded from a newer Mac — gets
                // no control. Approving something whose meaning is not in this binary is the
                // one thing a permission card must never do.
                continue
            }
        }
        return nil
    }
}

extension JSONValue {
    /// The first member with this key, or nil. Linear, which is right: a tool input has a
    /// handful of keys and `JSONValue` keeps them in document order deliberately (see its own
    /// comment), so there is no dictionary to consult and nothing to gain from building one.
    func member(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
}
