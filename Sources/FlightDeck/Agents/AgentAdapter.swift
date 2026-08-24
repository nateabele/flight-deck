import Foundation

/// Everything `SessionStore` needs from an agent, and nothing about how that agent works.
///
/// Four responsibilities: establish identity, produce the text typed into the pty, and
/// rename. Observation is deliberately NOT here — it belongs to `AgentRuntime`, because
/// both agents multiplex one source per account across that account's tabs rather than
/// owning a per-tab channel. See the design doc §2.1.
@MainActor
protocol AgentAdapter {
    static var id: AgentID { get }

    /// Establishes conversation identity BEFORE anything is typed into a terminal.
    ///
    /// This is the load-bearing method. Claude satisfies it by minting a UUID and binding
    /// the process to it; codex satisfies it by asking its app-server and being told. Either
    /// way the caller knows the conversation id and transcript path before a pty exists,
    /// which is what makes title sync and status attribution possible from the first byte.
    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding

    /// The binding for a tab whose conversation identity is ALREADY settled: one restored
    /// from a snapshot, or one the agent repointed at another conversation mid-flight.
    ///
    /// Separate from `prepare`, and synchronous, because those two cases are not identity
    /// negotiation — the store already holds the conversation id and is only asking the
    /// agent to describe what goes with it. Every path in `SessionStore` that needs one is
    /// synchronous up to `SessionStore.init` itself (`seedInitialSession` runs inside it),
    /// so an `async` answer there would mean creating tabs after the initializer returns.
    /// `prepare` stays `async` for the one case that genuinely negotiates: a new codex
    /// thread, which cannot be named until its app-server names it.
    func binding(for session: Session) -> AgentBinding

    /// Where this session's agent is working right now, paired with its binding.
    ///
    /// Both shipped agents use `transcriptDirectory` as their working directory, but that is a
    /// coincidence of two implementations, not a derivable rule — so every adapter states its
    /// own answer and the compiler catches one that forgets. The tools subsystem reads through
    /// this accessor alone, not `Session.transcriptDirectory` directly.
    func location(for session: Session) -> AgentLocation

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String

    /// The binding for a RESTORED tab, settled against what the agent still has.
    ///
    /// `binding(for:)` is a pure read of the pin and cannot tell a conversation that still
    /// exists from one deleted between launches. Claude does not need it to — its resume
    /// command carries its own fallback, `--resume <id> || --session-id <id>` — so the
    /// default below is claude's whole implementation. Codex has no such fallback: `codex
    /// resume <gone>` simply fails, so it settles identity with a round trip here and may
    /// hand back a *different* conversation. The caller re-pins when it does.
    func rebind(for session: Session, options: AgentOptions) async throws -> AgentBinding

    /// Renames the agent's own conversation. Claude types `/rename` into the pty; codex
    /// sends a request. Throwing is legal — the caller keeps the local title either way.
    func rename(_ binding: AgentBinding, to title: String) async throws

    /// The environment that binds a process to this account. Claude answers `CLAUDE_CONFIG_DIR`,
    /// codex `CODEX_HOME`; a third agent answers its own, and no caller ever learns which.
    func environment(for account: AgentAccount) -> [String: String]

    /// What to run, and what to type once it is up, to sign this account in.
    ///
    /// No default: there is no generically-correct answer, and a guessed one would silently
    /// ship a wrong login command for a future agent. Every conformer states its own.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation

    /// **How a message is typed into this agent's live terminal — or `nil`, which IS the
    /// refusal.**
    ///
    /// Everything `SessionStore` types into a running TUI goes through here: a phone's
    /// message (`submitPrompt`), `/rename <name>` (`flushPendingRename`), and a restore's
    /// "Keep going". All of them are text at a pty whose input box this build has to be able
    /// to find, and an agent whose box it cannot find is refused all three at one site —
    /// `inject` — because that is the single funnel all three pass through.
    ///
    /// **`nil` rather than a `Bool` beside a body, so the refusal is stated once.** A
    /// predicate and an implementation are two statements of one fact and they drift; a
    /// missing object cannot disagree with itself about whether it is missing.
    ///
    /// **Widening this back out is not the cautious move.** Nothing codex has goes through
    /// the funnel: `sendToShell` types resume commands and `initialInput` directly at the pty
    /// and never touches it, and `CodexAdapter.loginInvocation` has `inject: nil`, so no
    /// codex sign-in text is ever queued either.
    ///
    /// Read through `AgentID.textChannel` below, which is what the store consults.
    static var textChannel: AgentTextChannel? { get }

    /// **How a select-list dialog this agent has raised is driven — or `nil`, the refusal.**
    ///
    /// Split from `textChannel` because the two are genuinely different channels and an
    /// agent can have one without the other. Driving a dialog needs no input box and no kill
    /// ring: it is arrows counted against a screen grammar, a Return, and an Escape that
    /// reads nothing at all. Codex is exactly that case — its approval list fits
    /// `ChoiceDialog`'s model more closely than claude's own does, while its composer still
    /// has no answer to `inject`'s draft dance.
    ///
    /// Read through `AgentID.dialogDriver` below.
    static var dialogDriver: AgentDialogDriver? { get }

    /// **Whether this agent's conversation identity is a round trip that can fail, rather
    /// than a local mint.**
    ///
    /// Claude chooses the id itself and cannot be wrong about it. Codex is *told* one, by an
    /// app-server that has to be running to tell it, and can be told that the conversation
    /// the store held a pin for no longer exists.
    ///
    /// Three sites ask it, and they are the same question seen from two ends. `createSession`
    /// asks whether making a tab needs the `async` negotiation at all — an agent that mints
    /// locally takes the synchronous path and never spawns anything. `restore` and
    /// `reinsertClosed` ask whether the resume text must be DEFERRED until identity has been
    /// settled against the agent: `binding(for:)` is a pure read of the pin and cannot tell a
    /// conversation that still exists from one deleted between launches, so typing `codex
    /// resume <gone>` would open the tab onto an error instead of a session. Claude needs
    /// none of it, because its resume command carries its own fallback.
    ///
    /// No default, for the reason `loginInvocation` has none: `false` is claude's answer, and
    /// an agent that inherited it silently would have its identity treated as unfailable.
    static var negotiatesIdentity: Bool { get }

    /// **Whether something has to be RUNNING before `prepare`/`rebind` can be called.**
    ///
    /// Claude: nothing — its adapter is a pure function of paths. Codex: a probed binary, a
    /// spawned `codex app-server` and a completed handshake, per account.
    ///
    /// A predicate rather than the proposal's `func prepareRuntime() async throws`, and
    /// deliberately so. The *doing* is `SessionStore.startCodex`, and it is the store's by
    /// ownership rather than by accident: it memoizes one in-flight handshake per account in
    /// `codexHandshake`, builds through `makeCodexStackIfNeeded`, and tears the stack back
    /// down through `stopCodex(account:expected:)` on failure. A `CodexAdapter` is a value
    /// *produced by* one of those stacks, so moving the start onto it would mean moving the
    /// per-account stack registry onto the thing the registry hands out. That is an inversion,
    /// not a move — and this member is what the nine name checks needed either way.
    static var needsRuntimeStart: Bool { get }

    /// **Whether an external per-account status registry describes this agent's tabs.**
    ///
    /// Claude writes one file per session into `<home>/sessions` and `SessionStatusWatcher`
    /// scans it; codex reports through its app-server and has no such directory at all. Three
    /// sites ask: two decide whether to start an account's registry watcher, and one decides
    /// whether a registry tick may rebuild a tab's status — a scan that lists `claude`
    /// processes can neither confirm nor refute a codex thread, so rebuilding blindly would
    /// erase a codex tab's status on every tick.
    ///
    /// **A Bool rather than the proposal's `observationRoots(for:) -> [ObservationRoot]`, and
    /// this is the open question that proposal flagged, answered from inside the code.** The
    /// roots themselves cannot live here: `SessionStore.statusRoot(forAccount:)`,
    /// `transcriptsRoot(forAccount:)` and `codexIndexURL(for:)` each begin with a nil check
    /// on a store-owned override, and the property that makes a fixture run safe is that the
    /// override wins for EVERY account from ONE place (`AccountObservationRootTests`). An
    /// adapter answering with roots would either duplicate that check or lose it. And none of
    /// the three sites wants a list — each wants a yes or no, and would immediately
    /// destructure any list back into the call the store already makes. A type constructed
    /// only to be taken apart again has no reader.
    static var hasStatusRegistry: Bool { get }
}

/// **Typing a message into a live agent and submitting it.**
///
/// The body of `SessionStore.inject`, moved out from under the store so that "which screen
/// grammar" is the adapter's answer rather than a claude-shaped default reached by callers
/// carrying no agent at all.
///
/// **There is deliberately no `readiness(viewport:)` member.** A channel that could report
/// `.ready(draft:)` would be claiming to tell a real draft from a placeholder hint, and
/// `InputBar`'s own doc records that it cannot: Claude Code renders the hint in exactly the
/// shape of a draft and the two differ only in colour, which `ghostty_surface_read_text` does
/// not return. The safe reading is the kill itself — kill, then compare `content` before and
/// after — so the whole dance stays inside one call rather than being split across a question
/// that would have to guess.
@MainActor
protocol AgentTextChannel {
    /// Type `text` and submit it, preserving whatever draft was there — or refuse.
    ///
    /// **The contract the caller's bookkeeping depends on: `settle` is called exactly once
    /// iff this returns `true`.** `SessionStore` marks the tab mid-injection before calling
    /// and clears the mark inside the `settle` it supplies, so a channel that returned `true`
    /// without settling would leave the tab refusing every later injection for the life of
    /// the process.
    ///
    /// `stillWanted` is re-checked after the settle delay, because the request can be
    /// replaced or cancelled while the agent repaints. `onSent` runs once the text has been
    /// submitted, and is where the caller retires its pending entry.
    func submit(
        _ text: String,
        into injector: TextInjecting,
        settle: (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onSent: @escaping @MainActor () -> Void
    ) -> Bool
}

/// **Driving a select-list dialog the agent has raised.**
///
/// The interlock in front of an irreversible keypress, as `ChoiceDialog` documents it, with
/// the two things that are *not* shared between agents named as members: which row is the
/// plain approval, and how a refusal is delivered.
@MainActor
protocol AgentDialogDriver {
    /// Which row of the select list on screen the cursor is on, or nil when no list can be
    /// read, none is marked, or two are.
    func focusedRow(inViewport viewport: String) -> Int?

    /// The interlock: does row `index` read as `label`? False means refuse — never "count
    /// instead".
    func row(_ index: Int, reads label: String, inViewport viewport: String) -> Bool

    /// **The plain-approval row, and it has no default on purpose.**
    ///
    /// Both shipped agents order their approval dialogs the same way — plain yes, then a
    /// DURABLE GRANT, then deny — and both answer `0`. That coincidence is exactly why this
    /// must not be a defaulted constant: an agent that inherited `0` without checking would
    /// be one release away from silently granting "and don't ask again" from a pocket. Every
    /// conformer states its own, proved from that agent's own captured screens, and the
    /// compiler catches one that forgets.
    var allowRow: Int { get }

    /// Refusal with no reading at all — one key event, no viewport parse, no row arithmetic.
    /// It is the path a worried person reaches for from a pocket, and it is deliberately the
    /// one path that cannot be wrong about which row it is on, because it is not on a row.
    func deny(_ injector: TextInjecting)
}

extension AgentAdapter {
    /// Nothing to settle for an agent whose resume command already carries its own fallback.
    /// Being the default rather than a per-agent override is the point: an agent has to opt
    /// *in* to a round trip on the restore path, which is where the app is slowest and least
    /// able to report a failure.
    func rebind(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        binding(for: session)
    }

    /// The variable's name is the only agent-specific part, and `AgentID` already knows it —
    /// so this default is correct for every agent whose home is selected by one variable, and
    /// an agent that needs more can still override.
    func environment(for account: AgentAccount) -> [String: String] {
        [account.agent.homeEnvironmentKey: account.home.path]
    }
}

/// The capability questions the store asks about an agent it is holding by name.
///
/// A switch rather than a stored table, and a construction table rather than a policy: the
/// *answers* live on the adapters, which is what stops "can this be typed into" from being
/// re-decided at each call site, and the compiler makes a third agent state its own rather
/// than inherit claude's by default.
///
/// **Static, and that is load-bearing — it is why these are properties of `AgentID` rather
/// than methods on an adapter instance.** `SessionStore.adapter(for:)` answers codex out of
/// `makeCodexStackIfNeeded`, so asking an instance would memoize a stack and spin up a
/// runtime just to ask a question. The first caller is `restore`, which must be able to ask
/// about a codex tab before it has built anything for it, and `PromptService` holds only a
/// tab id. Neither can afford that, and neither should have to: a capability is a property
/// of the agent, not of one account's live stack. Nothing either channel does reads adapter
/// state — they read a screen and press keys — so there is nothing an instance would supply.
@MainActor
extension AgentID {
    /// See `AgentAdapter.textChannel`. Consulted at three sites in `SessionStore` —
    /// `restore`'s auto-resume gate, `submitPrompt` and `inject` — so none of them can come
    /// to a different conclusion about one agent.
    var textChannel: AgentTextChannel? {
        switch self {
        case .claude: ClaudeAdapter.textChannel
        case .codex: CodexAdapter.textChannel
        }
    }

    /// See `AgentAdapter.dialogDriver`. Consulted by `SessionStore.answerPrompt` and by
    /// `PromptService`, which is the split that stops those two drifting — the property
    /// `PromptService`'s own comment claims and used to fail at.
    var dialogDriver: AgentDialogDriver? {
        switch self {
        case .claude: ClaudeAdapter.dialogDriver
        case .codex: CodexAdapter.dialogDriver
        }
    }

    /// See `AgentAdapter.negotiatesIdentity`. Consulted by `createSession`, `restore` and
    /// `reinsertClosed`.
    var negotiatesIdentity: Bool {
        switch self {
        case .claude: ClaudeAdapter.negotiatesIdentity
        case .codex: CodexAdapter.negotiatesIdentity
        }
    }

    /// See `AgentAdapter.needsRuntimeStart`. Consulted by `preparedAdapter(for:)`.
    var needsRuntimeStart: Bool {
        switch self {
        case .claude: ClaudeAdapter.needsRuntimeStart
        case .codex: CodexAdapter.needsRuntimeStart
        }
    }

    /// See `AgentAdapter.hasStatusRegistry`. Consulted by `startStatusWatching()`,
    /// `startWatching(tabID:)` and `applyRegistry`.
    var hasStatusRegistry: Bool {
        switch self {
        case .claude: ClaudeAdapter.hasStatusRegistry
        case .codex: CodexAdapter.hasStatusRegistry
        }
    }
}

/// How to sign an account in. Two fields rather than one because the two agents differ in
/// shape: codex has a `login` subcommand, claude authenticates inside a running session.
struct LoginInvocation: Equatable, Sendable {
    let command: String
    let inject: String?
}
