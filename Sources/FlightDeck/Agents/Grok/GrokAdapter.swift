import FleetKit
import Foundation
import IntakeKit

/// grok's tab adapter (unify brief R10), built from a live probe of grok 1.0.30's TUI —
/// `.superpowers/grok-tui-facts.md` holds the evidence every member below cites.
///
/// **Identity is a local mint, like claude's.** `grok -s <uuid>` names a new session with any
/// RFC-4122 id Flight Deck chooses, and creates its directory at launch; `grok -r <uuid>`
/// resumes it from any cwd. So the tab's own id is the conversation id, nothing is negotiated,
/// and nothing needs to be running first.
@MainActor
struct GrokAdapter: AgentAdapter {
    static let id: AgentID = .grok

    /// The headless facet (unify brief R3): the same profile the planning runner reaches through
    /// `AgentProfiles.profile(for: .grok)`.
    nonisolated static var profile: any AgentProfile { AgentProfiles.profile(for: id) }

    static let textChannel: AgentTextChannel? = GrokTextChannel()
    static let dialogDriver: AgentDialogDriver? = GrokDialogDriver()
    static let openPromptReader: AgentOpenPromptReader? = GrokOpenPromptReader()
    static let searchCorpus: AgentSearchCorpus? = GrokSearchCorpus()

    /// **`nil`: `/rename <name>` is one submission**, typed through `textChannel` like claude's
    /// (probed: no modal, the slash menu row executes on Return with its argument). There is no
    /// second stage to drive.
    static let renameTyping: AgentRenameTyping? = nil

    /// **`nil`, and the facts say why.** grok retries transient failures itself (eight times by
    /// default) and has no `/retry` or `/continue`; a turn that still fails surfaces only as a
    /// `StopFailure` hook, which this build does not install (see `GrokStatusFold`), and no such
    /// failure was ever captured to build an allowlist from. An agent retries nothing until its
    /// classifier is built from captured records — `AgentAdapter.turnRecovery`'s rule.
    static let turnRecovery: AgentTurnRecovery? = nil

    static let negotiatesIdentity = false
    static let needsRuntimeStart = false

    /// `false`: grok has no claude-style per-account registry directory for
    /// `SessionStatusWatcher` to scan. Its status arrives through `GrokRuntime` as
    /// `.activity` events, the way codex's does.
    static let hasStatusRegistry = false

    /// Escape never cancels a grok turn — it shows a "press Ctrl+C" toast — and never answers a
    /// card. Ctrl+C does both (user guide ch. 3; a live Ctrl+C produced
    /// `StopCancelled{reason:user_interrupt}`).
    static let interruptKey: AgentInterruptKey = .controlC

    /// Control characters only, the shared half (`AgentTitle.sanitized`): the name is typed into
    /// grok's composer behind the same injection gate claude's is, and a pty is not a shell.
    nonisolated static func sanitizedTitle(_ raw: String) -> String? {
        AgentTitle.sanitized(raw, removing: CharacterSet())
    }

    /// grok's own title lives in `summary.json` beside the transcript, not in it: the auto
    /// title (`generated_title`, written a few seconds after the first turn) or a manual one.
    nonisolated static func title(fromTranscriptAt url: URL) -> String? {
        let summary = GrokSessionFiles.sibling(GrokSessionFiles.summaryName, of: url)
        return (try? Data(contentsOf: summary)).flatMap(GrokSessionFiles.summary(fromData:))?.title
    }

    nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
        GrokTimelineMapper.items(inLine: line, at: offset)
    }

    /// `$GROK_HOME/auth.json` (0600) is grok's login: its presence marks a grok home.
    nonisolated static let homeMarkerFile = "auth.json"

    /// The signed-in email, read from `auth.json` with no network. The file maps
    /// `"<issuer>::<client id>"` to a credential record carrying `email` (probed, values
    /// redacted). One distinct email or nothing: two logins in one file would make any one
    /// answer a plausible-looking wrong label, which `AgentAdapter` forbids.
    nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let emails = Set(root.values.compactMap { ($0 as? [String: Any])?["email"] as? String }
            .filter { !$0.isEmpty })
        guard emails.count == 1, let email = emails.first else { return nil }
        return AccountIdentity(email: email)
    }

    /// The grok home this adapter's account lives in, re-read on every derivation for the
    /// reason `ClaudeAdapter.projectsRoot` gives: a fixture root or a relocated account is
    /// assigned after construction.
    var home: () -> URL = { AgentID.grok.builtInHome }

    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        binding(for: session)
    }

    func binding(for session: Session) -> AgentBinding {
        AgentBinding(
            conversationID: session.pinnedConversationID,
            transcriptURL: GrokSessionFiles.transcriptURL(
                home: home(), workingDirectory: session.transcriptDirectory,
                conversationID: session.pinnedConversationID
            )
        )
    }

    /// grok works where it was launched; the tab's shell starts it in the transcript
    /// directory, as claude's does.
    func location(for session: Session) -> AgentLocation {
        AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
    }

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        "grok -s \(binding.conversationID.uuidString.lowercased())\(flags(options))\n"
    }

    /// **The fallback is in the command, because grok has none of its own.** An unknown id
    /// makes `grok -r` try a network restore and exit 1 ("Failed to restore session from
    /// remote … 404"), with no fresh session (probed). `grok -s <id>` is then valid precisely
    /// because the failed resume never created a directory for that id.
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        let id = binding.conversationID.uuidString.lowercased()
        let tail = flags(options)
        return "grok -r \(id)\(tail) || grok -s \(id)\(tail)\n"
    }

    /// The typed `/rename <name>` (`SessionStore.injectPendingRename`, through `textChannel`)
    /// IS grok's rename — it writes `summary.json` itself. There is no second channel to send
    /// on: writing that file from here would race the `summary.json.lock` grok holds while it
    /// runs. Nothing to do, so nothing fails.
    func rename(_ binding: AgentBinding, to title: String) async throws {}

    /// `grok login` signs in the home in `GROK_HOME`, which the sign-in tab's environment binds
    /// to this account (`PreferencesStore.sessionEnvironment`). OAuth in the browser; nothing
    /// is typed afterwards. Flight Deck shows it and never runs it unasked.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation {
        LoginInvocation(command: "grok login", inject: nil)
    }

    /// **What every grok tab needs: grok kept out of the other CLIs' config.** By default grok
    /// loads `~/.claude` hooks, MCP servers, rules, skills and agents (and Cursor's and
    /// Codex's) — so without these a grok tab would run the user's claude Stop hooks and
    /// qartez guards (probed with `grok inspect`). The compat switches are the same table
    /// `GrokProfile.isolationEnvironment` uses for planning, minus that table's
    /// `GROK_MEMORY=0` and autoupdater switch: those keep one planning seat from leaking into
    /// the next, and a person's own interactive grok keeps its memory and its updates.
    ///
    /// **`HOME` is NOT moved here, deliberately — see `environment(for:)` for where it is.**
    /// This dictionary lands on the tab's whole SHELL, and a shell whose `HOME` is a grok home
    /// loses the user's shell config, git identity and every `~` tool for the life of the tab.
    var launchEnvironment: [String: String] {
        GrokProfile.isolationEnvironment.filter { $0.key.hasSuffix("_ENABLED") }
    }

    /// The account binding, as unify brief R10 states it and `GrokProfile` does for planning:
    /// `GROK_HOME` AND `HOME` to the account's home, plus the isolation above. `HOME` matters
    /// because the compat switches do not cover Claude Code PLUGINS — grok discovers their hooks
    /// under `~/.claude/plugins` on a path no switch reaches, and only a `HOME` with no
    /// `.claude` in it stops them (facts §0.4).
    ///
    /// Consumed where a process is bound to the account as a whole — `ToolRunner`'s
    /// Tools-menu path — and not by the tab's shell, which takes `launchEnvironment` and the
    /// `GROK_HOME` that `PreferencesStore.sessionEnvironment` binds. The cost, recorded in the
    /// track report: a grok TAB still sees the user's Claude Code plugin hooks.
    func environment(for account: AgentAccount) -> [String: String] {
        var environment = launchEnvironment
        environment[GrokProfile.homeEnvironmentKey] = account.home.path
        environment["HOME"] = account.home.path
        return environment
    }

    /// `-m <model>` and `--effort <level>`, both accepted by the TUI (probed:
    /// `-m grok-4.7-build-fast --effort low` drew `Grok 4.7 Fast (low)`). Quoted, because a
    /// model id is user-typed text going to a shell.
    private func flags(_ options: AgentOptions) -> String {
        guard case .grok(let grok) = options else { return "" }
        return Self.flagTail(grok)
    }

    /// The tail itself, shared with Settings' launch-command preview so the preview is the
    /// command a tab types rather than a second spelling of it.
    static func flagTail(_ grok: GrokOptions) -> String {
        var out = ""
        if let model = grok.model, !model.isEmpty { out += " -m \(ClaudeSession.shellQuoted(model))" }
        if let effort = grok.effort, !effort.isEmpty { out += " --effort \(ClaudeSession.shellQuoted(effort))" }
        return out
    }
}
