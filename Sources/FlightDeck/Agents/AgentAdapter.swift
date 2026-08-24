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
    func environment(for account: AgentAccount) -> [String: String]

    /// What to run, and what to type once it is up, to sign this account in.
    ///
    /// No default: there is no generically-correct answer, and a guessed one would silently
    /// ship a wrong login command for a future agent. Every conformer states its own.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation
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

/// How to sign an account in. Two fields rather than one because the two agents differ in
/// shape: codex has a `login` subcommand, claude authenticates inside a running session.
struct LoginInvocation: Equatable, Sendable {
    let command: String
    let inject: String?
}
