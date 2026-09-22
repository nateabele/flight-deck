import FleetKit
import Foundation

/// Which coding agent a tab runs. The raw value is a storage format — it is written into
/// `sessions.json` — so it is spelled explicitly rather than derived from the case name.
enum AgentID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// What a prepared session is bound to: the agent's own conversation identity, and where
/// its transcript lives when the agent reports one.
///
/// `transcriptURL` is optional because the two agents learn it differently. Claude derives
/// it from the cwd; codex returns it from `thread/start`. An agent that reports neither is
/// still usable — it just has no transcript to tail.
struct AgentBinding: Equatable, Sendable {
    let conversationID: UUID
    let transcriptURL: URL?
}

/// Where an agent is working right now, and what it is bound to.
///
/// The adapter's answer to "describe this live session", so a caller never learns which agent
/// produced it. `AgentBinding` alone was not enough: it settles *identity*, which is fixed at
/// prepare time, while the working directory moves for the life of the tab — an agent that
/// enters a worktree changes where a tool should point without changing what it is bound to.
struct AgentLocation: Equatable, Sendable {
    let workingDirectory: String
    let binding: AgentBinding
}

/// One state-bearing thing an agent reported. The single vocabulary `SessionStore` speaks;
/// it never learns whether this arrived by tailing a file or by JSON-RPC notification.
///
/// Not a superset of `ClaudeSession.TranscriptEvent` — it sits at a different level of
/// abstraction. `TranscriptEvent`'s `agentStarted`/`agentFinished` are per-agent records;
/// `AgentRuntime` folds those into a running count before they ever reach here, so
/// `.subagentCount` carries the count, never an id. `.activity` has no `TranscriptEvent`
/// counterpart at all — it comes from claude's status registry, not the transcript.
enum AgentEvent: Equatable, Sendable {
    case title(String)
    case activity(SessionActivity)
    case subagentCount(Int)
    case turnEnded
    /// This tab's last turn died on an API error, or `nil` because a newer record cleared it.
    ///
    /// Like `.subagentCount` and unlike `.activity`, this is folded from transcript records
    /// before it reaches here — the store never learns which channel carried it. Claude reads
    /// this from its transcript's `isApiErrorMessage`; codex reads it from a `codex_error_info`
    /// field on its rollout's `task_complete` record — different shapes, same event.
    case apiError(SessionAPIError?)
    /// What this tab's agent lifecycle says about whether its input box is there to type
    /// into. Unlike `.activity`, which reports what the agent is *doing*, this reports
    /// whether there is anything to talk to at all. See `ComposerReadiness`.
    case lifecycle(ComposerReadiness)
    /// The user interrupted this tab's turn. Accompanies `.turnEnded`, never replaces it — an
    /// aborted turn is still a turn that ended, and a tab left spinning because nothing said
    /// "over" is the worse failure.
    ///
    /// Distinct from `.turnEnded` because the two answer different questions: `.turnEnded`
    /// asks whether the tab is free, this asks *who stopped it*. The auto-retry loop is the
    /// only reader, and the reason it needs one is that pressing Esc is the most natural way a
    /// person stops Flight Deck typing into their terminal — without this, the abort produced
    /// only `.activity(.idle)`, the schedule stayed armed, and the next rung typed again.
    ///
    /// **Codex-only in practice, and deliberately not invented for claude.** Claude's
    /// transcript makes an interrupt indistinguishable from any other user record: every
    /// `"type":"user"` record emits `.progressed` (`ClaudeSession.events(inObject:)`), and
    /// `.progressed` already clears `apiError` outright — schedule and all. So claude has no
    /// abort signal to map, and needs none: its loop is stopped by the clearing that its own
    /// interrupt record performs. Codex is the asymmetric case because its rollout reports
    /// `turn_aborted` as a record type of its own and clears no error.
    case turnAborted
}

/// Per-agent settings payload.
///
/// A union rather than a shared bag: claude's options are a command line (`FlagSet`, with a
/// catalog, parser, serializer and shell quoting behind it) while codex's are typed
/// `thread/start` params with no command line at all. Neither shape belongs in the other.
enum AgentOptions: Equatable, Sendable {
    case claude(FlagSet)
    case codex(CodexThreadOptions)

    var agent: AgentID {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

/// So `[AgentID: T]` encodes as a JSON object keyed `"claude"` / `"codex"` rather than Swift's
/// default alternating-array form. The stdlib supplies the whole implementation for a
/// `String`-backed `RawRepresentable` (SE-0320), which is why the body is empty — and the raw
/// values are already documented above as a storage format, so this keeps that promise legible.
extension AgentID: CodingKeyRepresentable {}
