import Foundation

/// **One transcript this agent has written, and everything the index needs to file it.**
///
/// Replaces `SearchCorpus.Entry`, which was `(projectPath, directory)` — a *directory per
/// project*, which is claude's `~/.claude/projects/<encoded-cwd>` layout baked into a type.
/// Codex has no such directory: its rollouts live in a date tree and record their cwd inside
/// the file. So an adapter hands back transcripts, not folders.
struct TranscriptRef: Equatable, Sendable {
    /// codex: the rollout. claude: `<conversation-uuid>.jsonl`.
    let url: URL

    /// The sidebar project this is attributed to.
    let projectPath: String

    /// The account home this transcript was found under — `CODEX_HOME` or
    /// `CLAUDE_CONFIG_DIR`. Carried per-transcript rather than left to the caller because a
    /// corpus is reached statically through `AgentID.searchCorpus` and holds no account of
    /// its own to consult.
    let accountHome: URL

    /// **The literal directory the conversation ran in** — the project itself, or one of its
    /// worktrees.
    ///
    /// Captured at walk time because that is the only moment it is known without guessing:
    /// claude's directory encoding is one-way (see `SearchCorpus`'s doc comment) and codex
    /// records its cwd only inside the file. Carrying it is what lets a search result resume
    /// into the worktree it actually ran in, instead of `SessionStore` re-deriving it by
    /// probing candidate directories for a matching filename.
    let workingDirectory: String

    let conversationID: String
    let agent: AgentID

    /// codex: `session_meta.payload.source` — "exec", "cli", "vscode". nil for claude.
    /// Drives the `.automated` ranking tier and nothing else.
    let provenance: String?

    /// The name this agent records for the conversation OUT OF BAND, if any — codex's
    /// `session_index.jsonl` entry. nil for claude, whose names are in the transcript itself.
    ///
    /// Resolved during the walk rather than on demand: the walk already visits each account
    /// once, so one read of that account's index serves every rollout under it. Resolving it
    /// per-conversation would mean re-reading that file once per rollout — 563 times on the
    /// machine this was measured on — or caching inside a `Sendable` type that is called off
    /// the main actor.
    let indexedName: String?

    let modified: Date
}

/// What a naming pass concluded, and how much authority it carries.
///
/// A verdict rather than a `String?` because the builder's overwrite rule needs to know
/// *why* it got a name. A later pass sees only newly appended lines, so a derived name must
/// never overwrite a real one an earlier pass already stored — the rule
/// `SearchIndexBuilder.containsRename` implements today for claude, generalised so each agent
/// states its own.
enum ConversationNaming: Equatable {
    /// A real rename. Overwrite whatever is stored.
    case authoritative(String)
    /// Derived — a first user message, or a placeholder. Write only when nothing is stored.
    case fallback(String)
    /// Nothing in this pass. Leave what is stored alone.
    case unknown
}

/// **Everything the ⌘K index needs from one agent, and nothing about how it stores it.**
///
/// Three jobs: find this agent's transcripts, turn one of its lines into indexable messages,
/// and say what a conversation is called.
///
/// **`Sendable` and non-isolated, unlike the other capability objects.** `textChannel`,
/// `dialogDriver` and `openPromptReader` are `@MainActor` because they drive a screen. This
/// one is called from inside the `SearchIndexBuilder` actor and a `Task.detached` within it
/// — the backfill runs off the main actor precisely so parsing hundreds of megabytes cannot
/// stall the agents running in the same process. Every member is therefore a pure function
/// of its arguments, with no cache and no lock.
protocol AgentSearchCorpus: Sendable {
    /// Every transcript this agent has written that belongs to one of `projects`, across
    /// every one of `accounts`.
    ///
    /// Accounts rather than one root: a transcript's home is per-account for both agents
    /// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Passing a single root is exactly the bug that
    /// makes ⌘K blind to a second claude login today.
    func transcripts(
        forProjects projects: [String], accounts: [AgentAccount]
    ) -> [TranscriptRef]

    /// One line of this agent's transcript, as indexable messages. Pure — the same shape as
    /// `AgentAdapter.timelineItems(inLine:at:)`, and tested the same way, from fixtures.
    func indexedMessages(
        inLine line: String, conversationID: String, at offset: Int
    ) -> [IndexedMessage]

    /// What this conversation is called, judged from the lines read in THIS pass plus
    /// whatever out-of-band name the walk already put on `ref`.
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming
}
