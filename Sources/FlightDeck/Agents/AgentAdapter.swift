import FleetKit
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

    /// Renames the agent's own conversation. Codex sends a request; claude's own leg never
    /// reaches this method at all — see `ClaudeAdapter.rename`'s doc comment for why. Throwing
    /// is legal — the caller keeps the local title either way.
    func rename(_ binding: AgentBinding, to title: String) async throws

    /// The environment that binds a process to this account. Claude answers `CLAUDE_CONFIG_DIR`,
    /// codex `CODEX_HOME`; a third agent answers its own, and no caller ever learns which.
    ///
    /// Composed of `launchEnvironment` plus the account's own variable, so a caller that has
    /// an account gets both without having to know there are two halves.
    func environment(for account: AgentAccount) -> [String: String]

    /// **What every process of this agent needs regardless of which login it runs as — or of
    /// whether it has one at all.**
    ///
    /// Separate from `environment(for:)` because that one takes a non-optional account, and
    /// the launch path has tabs with none: a login deleted between runs launches its shell
    /// with no account variable at all (see `SessionStore.insertSession`). Claude's
    /// hook-event directory belongs here rather than there for exactly that reason — it is
    /// how the agent reports its composer lifecycle, and a tab that reported nothing is a tab
    /// stuck on the legacy screen grammar forever.
    ///
    /// **This is the single expression of those variables, and it must stay single.** The
    /// event directory first shipped set only inside `environment(for:)`, whose sole
    /// production consumer is `ToolRunner` — so no launched session ever received it,
    /// `record.sh` exited on its first line, and the claude half of the hook feature was dead
    /// while every unit test around it passed. `AccountLaunchTests` now asserts this reaches
    /// `Ghostty.SurfaceConfiguration.environmentVariables`.
    var launchEnvironment: [String: String] { get }

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

    /// **How this agent's two-stage rename modal is driven at the pty — or `nil`, the
    /// refusal `ClaudeAdapter` states because it has no second stage to drive.**
    ///
    /// A separate capability from `textChannel` rather than a case inside `submit`, because
    /// codex's `/rename` is a MODAL with two submissions — `/rename`⏎ opens it, `<name>`⏎
    /// commits it — and needs a read in between to confirm the modal actually opened before
    /// the name is typed into it. `submit`'s shape has no room for that: one `text` parameter
    /// and one submission cannot carry a gate that depends on what the second submission
    /// reads off screen. See `AgentRenameTyping`'s doc comment for the rest of that reasoning.
    ///
    /// Read through `AgentID.renameTyping` below, which is what the store consults.
    static var renameTyping: AgentRenameTyping? { get }

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

    /// **How a turn this agent lost to an API failure is revived — or `nil`, the refusal.**
    ///
    /// A capability rather than a flag on the error, because the vocabulary is each agent's
    /// own: claude ships a transience predicate in its transcript record, codex ships a
    /// `codex_error_info` variant name and nothing else. Both answers are allowlists here —
    /// an unrecognised kind never retries — so an agent growing a new error kind cannot
    /// start typing into a terminal unattended. A `nil` is the refusal, exactly as it is for
    /// `textChannel`: an agent added later retries nothing until someone builds and tests
    /// its classifier against captured records.
    ///
    /// Read through `AgentID.turnRecovery` below.
    static var turnRecovery: AgentTurnRecovery? { get }

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

    // ─── Pure mappings and namings. `nonisolated`, because none of them touches actor
    //     state and three of them are reached from off the main actor: `TimelineReader` is
    //     `Sendable` and parses a page on a background queue, and `AccountDirectory` is
    //     reached from preference migration before any store exists. ───

    /// **A legal conversation name for THIS agent's rename channel.**
    ///
    /// Neither agent strips shell metacharacters. Claude's rename used to, because an
    /// injected `/rename <name>` could in theory reach a bare shell rather than a live
    /// claude — but `SessionStore.inject` now gates on a rule-sandwiched composer box
    /// actually being on screen (see `ClaudeTextChannel`), a bare shell never draws that, and
    /// with the gate load-bearing the strip only cost the user their punctuation. Codex's
    /// rename travels TWO channels and neither one is a shell: `CodexAdapter.renameTyping`
    /// types `/rename`, then the name, at a pty (`CodexTextChannel.submitRename`), and
    /// `SessionStore` separately sends `thread/name/set`, which is what actually commits the
    /// thread. **A pty is not a shell** — the typing lands in a rename modal codex itself
    /// drew, and when it cannot read that modal `submitRename` escapes rather than typing **the
    /// name** (the fixed `/rename` literal has gone out by then; what the guard withholds is the
    /// user-supplied string, the only part a strip would ever have touched) — so a strip there
    /// never protected anything either; it only mangled the title.
    /// Both converge on `AgentTitle.sanitized` with an empty forbidden set; see its own doc
    /// comment.
    ///
    /// Control characters ARE stripped for EVERY agent — `AgentTitle.sanitized`, which holds
    /// the half both agents share — so a newline still cannot be smuggled into either agent's
    /// modal. Do not reintroduce a shell-metacharacter strip for either agent: the hazard it
    /// guarded against is a name reaching a **shell prompt**, and for claude that is closed by
    /// the injection gate above rather than by this function, while for codex the name never
    /// had a shell to reach. Typing at a pty is not the hazard; typing at a *shell* is.
    nonisolated static func sanitizedTitle(_ raw: String) -> String?

    /// **A conversation's own name, read out of its transcript** — for a tab that repointed
    /// at a conversation this app did not start.
    ///
    /// Claude: `ConversationTitle.resolve`, which mirrors what `claude`'s own `/resume`
    /// picker shows. Codex: `nil`, and that is an answer rather than a gap — a codex thread's
    /// name lives in `session_index.jsonl` and reaches the store through `CodexNameWatcher`,
    /// never out of the rollout. Handing a codex rollout to claude's JSONL parser is exactly
    /// what the store used to do by default.
    nonisolated static func title(fromTranscriptAt url: URL) -> String?

    /// **One line of this agent's transcript, as timeline items.**
    ///
    /// The pattern the rest of this protocol was written to match rather than a site that
    /// needed fixing: two pure functions with one signature, tested from captured fixtures,
    /// refusing rather than guessing. All that moves is where the switch lives.
    nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem]

    /// **The file whose presence marks a directory as one of this agent's homes**, and what
    /// that file says about who is signed in.
    ///
    /// Identity is display-only, so a wrong answer must degrade to "no answer" — never to a
    /// plausible-looking wrong email next to a real account.
    nonisolated static var homeMarkerFile: String { get }
    nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity?

    /// **How this agent's transcript says what it is blocked on — or `nil`, the refusal.**
    ///
    /// The third capability object, and the other half of `dialogDriver`. Driving a dialog
    /// needs a screen grammar; knowing *which* dialog is on screen needs a transcript
    /// grammar, and an agent can have either without the other. Codex is exactly that case:
    /// its approval list is drivable, and it writes nothing to its rollout when that list
    /// goes up (`CodexEventMapper`), so there is no record to find and no call id for a
    /// phone's tap to be checked against.
    ///
    /// **An object rather than a method returning `nil`, for the same reason the other two
    /// are.** A method's `nil` would mean both "no dialog is open" and "this agent has no
    /// derivation", and those are different sentences on a phone — `prompt_changed` versus
    /// `unsupported_agent`. It also lets `PromptService` refuse before reading the file.
    static var openPromptReader: AgentOpenPromptReader? { get }

    /// **How this agent's history becomes searchable — or `nil`, the refusal.**
    ///
    /// The fourth capability object, and one of the two that are not `@MainActor` (with
    /// `AgentOpenPromptReader`) — see `AgentSearchCorpus`'s own doc comment for why. `nil` means this agent contributes
    /// nothing to ⌘K, which is an answer the overlay can state rather than a gap that reads
    /// as "you have no conversations here".
    ///
    /// Deliberately has NO default implementation. The defaults in this file exist for
    /// members with a genuine majority answer (`rebind`, `environment`); this has none, and a
    /// silent default is how a third agent would ship looking searchable and finding nothing.
    static var searchCorpus: AgentSearchCorpus? { get }
}

/// Deriving what an agent is blocked on from a window of its transcript.
///
/// A window rather than the whole file because an agent cannot proceed past a dialog, so the
/// open call is always among the last *conversational* records; a few rather than one so that
/// a result for an *earlier* call is inside the window and cannot make an already-answered call
/// look open — the only way this can be wrong in the dangerous direction. **A conformer must
/// not treat "nothing found in this window" as proof there is no open call**, though — an agent
/// can interleave non-conversational bookkeeping records into the same transcript file (Claude
/// Code does; see `ClaudeOpenCall`'s own doc comment), and a run of those can crowd a real
/// dialog out of a small window even though the transcript holds more history above it. The
/// caller (`PromptService.openPrompt(inSession:)`) is what widens the window when that happens;
/// this protocol's `openPrompt(inTranscriptTail:activity:)` stays a pure, single-window
/// derivation and returns `nil` for "not in this window", not "does not exist".
///
/// **`Sendable` and not `@MainActor`**, because `PromptService` runs a widened read on a
/// background queue: on a transcript with no open call that read is a scan of up to 8MB, and
/// on the main actor it pinned Flight Deck at 112% CPU. A conformer is a pure function of its
/// arguments, so this costs it nothing.
protocol AgentOpenPromptReader: Sendable {
    func openPrompt(inTranscriptTail lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt?

    /// Where this agent writes its background subagents' transcripts for the conversation in
    /// `transcript`, or nil if it has none.
    ///
    /// **A dialog can be on screen with its call in one of these files and not in the tab's
    /// own transcript.** claude draws a background subagent's permission dialog in the parent's
    /// TUI and sets the parent `waiting`, but writes the `tool_use` to the subagent's file.
    /// `PromptService` looks here so it does not report such a tab as having nothing open.
    /// No default: an agent that has subagents and answers nil would bring that bug back.
    func subagentTranscripts(for transcript: URL) -> URL?
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
    /// Whether this agent's input box is on screen AND empty right now.
    ///
    /// **Diagnostic only — nothing gates typing on this.** Injection is gated on presence
    /// (`hasComposerBox`, or `isKnownNonComposer` once the agent has reported itself live —
    /// see `SessionStore.injectionGate`), and `submit()` decides empty-vs-draft by killing and
    /// comparing, so this member no longer sits on the typing path. Its sole caller is the
    /// `composer=` field of `promptTypingComposerState`'s log string. It answers `false` for a
    /// box that cannot be read or that holds anything other than the queued-messages hint.
    func isComposerEmpty(_ injector: TextInjecting) -> Bool

    /// Whether this agent's own composer is genuinely on screen right now — as opposed to a
    /// dialog, a bare shell, or a screen this build cannot read.
    ///
    /// **This is what `SessionStore.injectionGate` asks of a tab whose agent has not reported
    /// its lifecycle** — `ComposerReadiness.unknown`: a session restored from an older build,
    /// one whose hook plugin never loaded, one in a folder claude does not trust. It replaced
    /// the status-file activity check, which said nothing about what was actually on screen:
    /// `.busy` and `.idle` both draw the composer, a `.waiting` dialog draws something that
    /// only looks like it, and a pre-boot bare shell draws neither. Each agent answers this
    /// from its own screen grammar — see `ClaudeTextChannel`'s rule-sandwich and
    /// `CodexTextChannel`'s footer check — so the gate stays correct without `SessionStore`
    /// knowing either one.
    ///
    /// A tab that HAS reported `.live` is gated on `isKnownNonComposer` below instead, because
    /// this predicate's failure direction is the wrong one to stand alone on: it must
    /// recognise a composer, so an agent that restyles one stops accepting injection
    /// altogether. This stays the fallback precisely because "unsure" answering `false` is the
    /// safe reading when nothing else has vouched for the session.
    ///
    /// Presence only, never emptiness: a box that is on screen but holds a draft still answers
    /// `true` here, because `submit`'s kill-and-compare is what decides whether that draft can
    /// be preserved.
    func hasComposerBox(_ injector: TextInjecting) -> Bool

    /// Whether the screen positively shows a dialog covering this agent's composer.
    ///
    /// **The inversion of `hasComposerBox`, and that is the point.** A predicate that must
    /// recognise a *composer* fails closed when the rendering drifts: injection stops
    /// working on a claude or codex update, silently, in production. A predicate that only
    /// fires on a positively-recognised *dialog* fails open instead — an unfamiliar
    /// composer variant still gets typed into. So **unsure answers `false`**, including when
    /// the screen cannot be read at all.
    ///
    /// It is nevertheless load-bearing rather than a backstop, and it is the ONLY defence
    /// against a dialog: hook lifecycle events answer "is this session booted and alive", not
    /// "what is on screen". Probing established that denying a permission prompt with Esc
    /// fires no hook whatsoever, and that claude raises select-list dialogs of its own right
    /// after `Stop` — so the event stream cannot cover either case, and a dialog this misses
    /// is a dialog Flight Deck types into.
    ///
    /// **No protocol-extension default, for the reason `allowRow` gives below.** A defaulted
    /// `false` reads as "this agent never raises a dialog", which is true of no agent; a new
    /// conformer would inherit it and ship with the veto silently disabled. Every conformer
    /// states its own rule, proved against that agent's own captured screens — see
    /// `ClaudeDialogVetoTests` and `CodexDialogVetoTests` — and the compiler catches one that
    /// forgets.
    func isKnownNonComposer(_ injector: TextInjecting) -> Bool

    /// Type `text` and submit it, preserving whatever draft was there — or refuse.
    ///
    /// Returns false having sent nothing. Returns true and then runs `onFinished` EXACTLY ONCE
    /// — on every path, including a request superseded mid-repaint. `onFinished(true)` means
    /// the text was submitted; `onFinished(false)` means it never was, and the conformer has
    /// unwound cleanly instead, putting back any draft its probe killed.
    ///
    /// **`settle` may be called more than once — once per repaint the conformer must wait
    /// through — and it is `onFinished` that carries that one-shot guarantee, exactly as it
    /// does for `AgentRenameTyping.submitRename`.** A single settle was once the whole
    /// contract, and `ClaudeTextChannel` still only ever needs the one; `CodexTextChannel`
    /// needs a second, later hop so its Return is never issued in the same settle as the text
    /// before it — codex paste-detects that burst and inserts a newline instead of submitting
    /// (see `CodexTextChannel.submit`'s doc comment).
    ///
    /// **The `Bool` is not decoration, and the two halves of what the caller does with it are
    /// not the same condition.** `SessionStore` marks the tab mid-injection before calling and
    /// releases that mark in `onFinished` regardless of the outcome, because a channel that
    /// returned `true` and then finished without saying so would leave the tab refusing every
    /// later injection — renames and phone prompts alike — for the life of the process. That
    /// was a live defect on both conformers' superseded paths, not a hypothetical. But the
    /// caller's *pending entry* may only be retired on `true`: when a rename is superseded,
    /// the entry already holds the NEWER name, so retiring it would silently drop the
    /// replacement. Release is unconditional; retirement is not.
    ///
    /// `stillWanted` is re-checked after the first settle delay, because the request can be
    /// replaced or cancelled while the agent repaints.
    func submit(
        _ text: String,
        into injector: TextInjecting,
        settle: @escaping (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (Bool) -> Void
    ) -> Bool
}

/// **The second stage of a rename that cannot be said in one shot.**
///
/// `AgentTextChannel.submit` types one message and submits it, and its guarantee already
/// rides on `onFinished` rather than on a settle count: `CodexTextChannel.submit` needs two
/// hops of its own, so its Return is never issued in the same settle as the text before it
/// (see that type's doc comment), and `SessionStore` releases its `injecting` mark inside
/// whichever `onFinished` the channel is handed — never inside a settle — so "returns `true`"
/// and "settles" do not have to name the same moment.
///
/// Codex's `/rename` pushes that further: it is a MODAL with two submissions — `/rename`⏎
/// opens it, `<name>`⏎ commits it — so there are two screen repaints to wait through, plus a
/// read in between to confirm the modal actually opened before the name is typed into it.
/// `submit`'s shape has no room for that: one `text` parameter and one submission cannot
/// carry a gate that depends on what the second submission reads off screen.
///
/// So this protocol carries the same guarantee `submit` does, on the same terms: `settle`
/// may be called any number of times — once per stage that needs the terminal to catch up —
/// and it is **`onFinished`** that fires exactly once on every path (success, a refused
/// modal, or cancellation), which is the caller's cue that it may finally release its mark.
@MainActor
protocol AgentRenameTyping {
    /// Returns false having sent nothing. Returns true and then runs `onFinished` EXACTLY ONCE —
    /// on every path, including cancellation and a refused modal. `settle` may be called any
    /// number of times. `onFinished(true)` means the name was submitted.
    ///
    /// The exactly-once guarantee is the conformer's to keep, but it is conditional on the
    /// caller: it holds only if `settle`'s own closure argument is invoked exactly once per
    /// call. A `settle` that drops a call leaves `onFinished` unfired and the caller's mark
    /// held forever; a `settle` that fires twice can run a later stage's work twice. Callers
    /// implementing `settle` — most likely once, for the app — must honor that contract for
    /// this guarantee to mean anything.
    func submitRename(
        _ name: String,
        into injector: TextInjecting,
        settle: @escaping (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (Bool) -> Void
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

    /// **Is a select list on screen at all** — the one screen fact the planned answer drive
    /// checks before each press.
    ///
    /// `AnswerPlan` has already computed every keystroke from the transcript and the reader's
    /// choices, so the drive is a fixed program and the screen's only remaining job is to say
    /// that the program still has something to type into. Deliberately looser than
    /// `focusedRow`: it reads the last marker line and nothing else, so an option's own wrapped
    /// description cannot defeat it — which `focusedRow` does, on
    /// `Fixtures/Claude/question-numbered-description.captured.txt`.
    ///
    /// **The predicate is shared with the injection veto, and the cost of a wrong answer points
    /// the OTHER WAY here.** `ChoiceDialog.hasNumberedRowAtMarker` is written loose on purpose
    /// for `AgentTextChannel.isKnownNonComposer`, where being too strict types a message into a
    /// live dialog and being too loose only refuses an injection somebody can retry. In this
    /// duty the loose direction is the expensive one: a false "yes" — a one-row draft beginning
    /// `1. `, the false positive that doc names and accepts — is a Return fired into a composer
    /// holding somebody's unsent text. Nothing here tightens it, because the screen carries no
    /// attributes that would tell the two apart and the earlier gates (`statuses[id] ==
    /// .waiting`, the transcript's own open prompt) are what actually keep a composer out of
    /// this path. Recorded so that the next person to widen it knows both duties are reading it.
    ///
    /// **No default here either, for `allowRow`'s reason.** Every conformer states its own
    /// agent's marker; a defaulted one would apply claude's grammar to somebody else's screen.
    func hasSelectList(inViewport viewport: String) -> Bool

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

/// Whether a failed turn is worth retrying, and what revives it. See
/// `AgentAdapter.turnRecovery`.
@MainActor
protocol AgentTurnRecovery {
    func retries(_ error: SessionAPIError) -> Bool
    var resumeText: String { get }
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
    ///
    /// The agent's own `launchEnvironment` is folded in here rather than left to each caller
    /// to remember, and the account wins any collision: the account variable is the one thing
    /// nothing else may repoint (see `PreferencesStore.sessionEnvironment`).
    func environment(for account: AgentAccount) -> [String: String] {
        var environment = launchEnvironment
        environment[account.agent.homeEnvironmentKey] = account.home.path
        return environment
    }

    /// Nothing beyond the account binding, for an agent that reports no lifecycle of its own.
    /// Codex takes this default: its readiness comes from rollout evidence on disk, which
    /// needs no variable in the child's environment.
    var launchEnvironment: [String: String] { [:] }
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

    /// See `AgentAdapter.renameTyping`. Consulted by `SessionStore.flushPendingRename`,
    /// alongside `rename`'s `thread/name/set` — which it does not wait for — to type the same
    /// name at the pty that call cannot reach.
    var renameTyping: AgentRenameTyping? {
        switch self {
        case .claude: ClaudeAdapter.renameTyping
        case .codex: CodexAdapter.renameTyping
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

    /// See `AgentAdapter.turnRecovery`. Consulted by `SessionStore`'s arming gate alone, so
    /// the retry loop never learns an agent's name.
    var turnRecovery: AgentTurnRecovery? {
        switch self {
        case .claude: ClaudeAdapter.turnRecovery
        case .codex: CodexAdapter.turnRecovery
        }
    }

    /// See `AgentAdapter.openPromptReader`. Consulted by `PromptService` alone — the store is
    /// handed the derived `OpenPrompt` and never derives one itself.
    var openPromptReader: AgentOpenPromptReader? {
        switch self {
        case .claude: ClaudeAdapter.openPromptReader
        case .codex: CodexAdapter.openPromptReader
        }
    }

    /// See `AgentAdapter.searchCorpus`. Consulted by `SearchIndexBuilder`, reached through
    /// `AppDelegate.startSearch`'s backfill kickoff, which holds no adapter at all — which is
    /// the whole reason the capability hangs off the agent rather than off an instance.
    ///
    /// `nonisolated` unlike its siblings here: `SearchIndexBuilder` calls it directly from
    /// inside its own actor, off the main actor, and the object it returns is `Sendable`.
    nonisolated var searchCorpus: AgentSearchCorpus? {
        switch self {
        case .claude: ClaudeAdapter.searchCorpus
        case .codex: CodexAdapter.searchCorpus
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

/// The pure mappings, read the same way and kept in their own extension because they are
/// **nonisolated**: `TimelineReader` maps a page off the main actor, and `AccountDirectory`
/// answers preference migration before a store exists. Same construction table, same reason
/// — the answers live on the adapters so a third agent states its own.
extension AgentID {
    /// See `AgentAdapter.sanitizedTitle`. Consulted by `SessionStore.rename`,
    /// `injectPendingRename` and `applyExternalTitle`.
    func sanitizedTitle(_ raw: String) -> String? {
        switch self {
        case .claude: ClaudeAdapter.sanitizedTitle(raw)
        case .codex: CodexAdapter.sanitizedTitle(raw)
        }
    }

    /// See `AgentAdapter.title(fromTranscriptAt:)`. Consulted by `SessionStore.titleResolver`'s
    /// default, which is what `repin` reaches.
    func title(fromTranscriptAt url: URL) -> String? {
        switch self {
        case .claude: ClaudeAdapter.title(fromTranscriptAt: url)
        case .codex: CodexAdapter.title(fromTranscriptAt: url)
        }
    }

    /// See `AgentAdapter.timelineItems(inLine:at:)`. Consulted by `TimelineReader.page`.
    func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
        switch self {
        case .claude: ClaudeAdapter.timelineItems(inLine: line, at: offset)
        case .codex: CodexAdapter.timelineItems(inLine: line, at: offset)
        }
    }

    /// See `AgentAdapter.homeMarkerFile`. Consulted by `AccountDirectory`.
    var homeMarkerFile: String {
        switch self {
        case .claude: ClaudeAdapter.homeMarkerFile
        case .codex: CodexAdapter.homeMarkerFile
        }
    }

    func identity(fromHomeData data: Data) -> AccountIdentity? {
        switch self {
        case .claude: ClaudeAdapter.identity(fromHomeData: data)
        case .codex: CodexAdapter.identity(fromHomeData: data)
        }
    }

}

/// How to sign an account in. Two fields rather than one because the two agents differ in
/// shape: codex has a `login` subcommand, claude authenticates inside a running session.
struct LoginInvocation: Equatable, Sendable {
    let command: String
    let inject: String?
}
