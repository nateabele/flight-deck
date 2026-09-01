import FleetKit
import Foundation

/// Codex conformance, driven over `codex app-server` JSON-RPC rather than by typing at a pty.
///
/// The inversion versus claude is deliberate and forced by the tool: codex assigns thread
/// ids itself, so identity is *returned* rather than minted. What matters is that it is
/// still known before a terminal exists, which is the property the rest of the app relies on.
@MainActor
struct CodexAdapter: AgentAdapter {
    static let id: AgentID = .codex

    /// **Not yet — and this is a capability answer, not a permanent verdict.** Whoever makes
    /// codex typeable writes the channel and returns it here; nothing else in `SessionStore`
    /// or `PromptService` re-decides it by name.
    ///
    /// Two halves, and they no longer have the same status:
    ///
    /// - **Typing a turn is foreclosed on the app-server route, permanently.** A codex tab is
    ///   a `codex resume <id>` TUI holding the thread's writer lock, and `prepare`'s own probe
    ///   recorded the answer: `thread/resume failed: thread <id> already has an active writer
    ///   (code -32600)`. Metadata survives that lock — which is why `thread/name/set` renames
    ///   work — but a turn does not.
    /// - **Typing at the pty is unbuilt, not impossible.** A capture against codex-cli 0.148.0
    ///   settles what the shipped refusal assumed: codex's input marker is `›` (U+203A) and
    ///   claude's is `❯` (U+276F), and `InputBar.read` keys on `❯` as the first
    ///   character — so it matches *nothing at all* on a codex screen. The near-miss
    ///   `SessionStore.rename` records was never "InputBar found codex's box"; it was
    ///   "InputBar keys on a glyph a bare shell prompt also draws" — a risk about the shell,
    ///   and unchanged. What is still missing is a reader that accepts codex's composer and
    ///   rejects a shell prompt, and an answer to `inject`'s draft dance: Ctrl-Y restores
    ///   only because Claude Code keeps a deleted-text ring, and codex has not been shown to.
    static let textChannel: AgentTextChannel? = nil

    /// **The closer of the two, and now a separate question.** Driving a dialog needs no
    /// input box and no kill ring, so everything blocking `textChannel` above is irrelevant
    /// to it: codex's approval list is nearer `ChoiceDialog`'s model than claude's own —
    /// contiguous numbering, one marker on the focused row, blank-line termination, a stable
    /// footer, and an echoed prompt that carries the marker with no number — so
    /// marker-and-number-and-neighbour is the right defence there too.
    ///
    /// What does NOT transfer is the row ordering: codex's row 1 is a durable grant (`Yes,
    /// and don't ask again for commands that start with …`) and row 2 is deny, so "the first
    /// row, and only ever the first row" is exactly as load-bearing for codex as
    /// `SessionStore.answerPrompt` says it is for claude, and must be proved from a capture
    /// rather than inherited — which is why `AgentDialogDriver.allowRow` has no default, and
    /// why `CodexDialogDriver.allowRow` states codex's own from codex's own screen.
    ///
    /// **What this does and does not turn on.** It makes `answerPrompt` willing to drive a
    /// codex dialog; it does not make one reachable from a phone, because
    /// `openPrompt(inTranscriptTail:)` below is `nil` and a codex tab never reports `waiting`
    /// in the first place. Both of those are features nobody has built, stated as `nil`
    /// rather than hidden inside a name check.
    static let dialogDriver: AgentDialogDriver? = CodexDialogDriver()

    /// Codex assigns thread ids itself, so identity is *returned* rather than minted — and
    /// the round trip can come back saying the thread is gone, which is why a restored codex
    /// tab has its resume text deferred until `rebind` has settled it.
    static let negotiatesIdentity = true

    /// A probed binary, a spawned `codex app-server` and a completed handshake, before
    /// `prepare` or `rebind` can be called at all. See `SessionStore.startCodex`, which owns
    /// the per-account memoization this predicate gates.
    static let needsRuntimeStart = true

    /// Codex has no per-account status directory: it reports through its app-server, and
    /// `CodexRuntime` is what turns that into a status. A `claude` registry scan can neither
    /// confirm nor refute a codex thread.
    static let hasStatusRegistry = false

    /// **Trim, control-strip and cap — and NO shell-metacharacter strip, which is a
    /// deliberate change to shipped behaviour.**
    ///
    /// `SessionStore.rename` used to run every agent's title through
    /// `ClaudeSession.sanitizedName`, whose metacharacter strip exists because claude's
    /// rename is *typed at a pty that may be a bare shell*. Codex's rename is
    /// `thread/name/set` over JSON-RPC: no shell, no pty, no quoting, at any point on the
    /// path. The strip therefore bought nothing and cost the user their punctuation —
    /// `fix build (part 2)` became `fix build part 2` in codex's own thread list, in
    /// `session_index.jsonl`, and in the sidebar.
    ///
    /// Control characters are still stripped, and that is not the shell rule under another
    /// name: a newline in a title breaks a sidebar row whatever the channel. See `AgentTitle`.
    nonisolated static func sanitizedTitle(_ raw: String) -> String? {
        AgentTitle.sanitized(raw, removing: CharacterSet())
    }

    /// **`nil`, and that is an answer rather than a gap.** A codex thread's name lives in
    /// `session_index.jsonl` and reaches the store through `CodexNameWatcher`; the rollout
    /// carries conversation content, not a name. Returning claude's parser here would hand a
    /// codex rollout to a claude JSONL parser, which is exactly what the store's default did.
    nonisolated static func title(fromTranscriptAt url: URL) -> String? { nil }

    nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
        CodexTimelineMapper.items(inRolloutLine: line, at: offset)
    }

    /// `<home>/auth.json` → the `email` claim of `tokens.id_token`.
    nonisolated static let homeMarkerFile = "auth.json"

    nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? {
        AccountDirectory.codexIdentity(from: data)
    }

    /// **`nil`, and this is the half of the answer path codex does not have.** Codex writes
    /// nothing to its rollout when an approval prompt goes up — verified with a prompt live
    /// on screen, recorded in `CodexEventMapper` — so there is no record to find and no call
    /// id to compare a phone's tap against. `dialogDriver` above can drive the dialog; this
    /// is what would tell it *which* dialog, and it does not exist yet.
    ///
    /// The buildable route is `thread/read`'s `activeFlags`, which
    /// `CodexThreadStatus.activity` already maps to `.waiting` and nothing polls. That is a
    /// feature, not a refusal — see the audit's §3.2 part 1.
    static let openPromptReader: AgentOpenPromptReader? = nil

    let rpc: CodexRPC

    /// Deadline for `read`, in seconds. `CodexRPC.request` has none of its own — only the
    /// handshake verifier produces `.timeout` — and `read` is the one call a *restored* tab
    /// waits on before anything can be typed at it. A property rather than an argument so it
    /// stays out of the `AgentAdapter.rebind` signature, which is not codex's to shape.
    var readTimeout: Double = 5

    /// Set by `SessionStore.startCodex` from the probed codex version, before `prepare` can
    /// be reached — `nil` means this codex predates the `historyMode` param, and its own
    /// default is already `legacy`; a non-nil value is always `"legacy"`. See
    /// `CodexThreadOptions.asThreadStartParams(cwd:historyMode:)` for why pinning it here is
    /// deliberate rather than a `config.toml` override this app should be leaving alone.
    var historyMode: String?

    /// The seam `prepare`'s history-contract check calls through, so the diagnostic added
    /// there is testable without a real codex on disk. Defaults to an actual filesystem
    /// check, matching `CodexVersionProbe.run`'s injected default for the same reason: a
    /// test may override it, production never needs to.
    var rolloutExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    /// Start, then name, then archive/unarchive. NOT optional and NOT reorderable.
    ///
    /// `thread/start` does not persist anything: no `threads` row, no rollout file, even
    /// with the app-server left alive. `thread/name/set` — issued to the same app-server
    /// process — commits it. This is the `legacy` history contract, which
    /// `CodexAdapter.historyMode` pins on codex builds new enough to accept it; see the guard
    /// below for what changes under `paginated`, codex-cli 0.151.0's new default. Skip the
    /// name and `codex resume <id>` dies with `ERROR: No saved session found with ID …`,
    /// which is a tab that can never launch. Naming costs nothing anyway: the tab already
    /// has the title we want to set. The archive/unarchive round trip that follows releases
    /// the writer lock
    /// `thread/start` took out — see the comment at that call below for why it exists and
    /// must come after naming, not before.
    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        let params = threadOptions(options).asThreadStartParams(
            cwd: session.transcriptDirectory,
            historyMode: historyMode
        )
        let result = try await rpc.request("thread/start", params)

        guard let thread = result["thread"] as? [String: Any],
              let raw = thread["id"] as? String,
              let id = UUID(uuidString: raw)
        else { throw CodexRPCError.malformed("thread/start returned no usable thread id") }

        // Commit — under the `legacy` history contract this call is pinned to; see the
        // guard below for `paginated`. A failure here must propagate: a bound-but-uncommitted
        // thread is worse than no tab, because it looks fine until the terminal reports it
        // cannot resume.
        //
        // Cross-agent audit (spec rule: no failure or recovery path may rename a
        // conversation): codex is compliant. `prepare` is reached only from a user action
        // (`newSession`) or from `rebind`'s thread-gone recovery branch below — and in both
        // cases this `thread/name/set` names a BRAND-NEW thread, not the user's real one;
        // under `legacy` history, codex simply cannot persist a thread without naming it. So
        // on the recovery path the user's real conversation is never renamed — it is gone,
        // and a fresh, separately named thread takes its place. One residual asymmetry
        // versus claude: claude's recovery path (the `AgentAdapter.rebind` default) writes
        // no name at all, while codex's writes `session.title` onto the new thread.
        _ = try await rpc.request("thread/name/set", ["threadId": raw, "name": session.title])

        // Confirm the rollout `thread["path"]` names actually exists, RIGHT HERE and nowhere
        // else — both facts below came from driving a live app-server, not from reasoning
        // about it, and moving this check breaks it in opposite directions:
        //
        // - Under `legacy` history, the rollout does NOT exist the instant `thread/start`
        //   above returns, and DOES exist the instant `thread/name/set` above returns —
        //   verified deterministically across four consecutive threads. So this cannot move
        //   before naming: it would fire on every healthy thread.
        // - `thread/archive` below MOVES the rollout out of `sessions/` as part of releasing
        //   the writer lock. So this cannot move after archiving either: it would fire on
        //   every healthy thread, for the opposite reason. (An early probe in this
        //   investigation looked flaky for exactly that reason before the move was
        //   understood.) No polling, no retry, no sleep — it is deterministic at this one
        //   point and nowhere else.
        //
        // What it exists to catch: codex-cli 0.151.0 flipped the default thread-history
        // contract from `legacy` to `paginated`, under which nothing writes a rollout for a
        // thread that has taken no turn yet — so `thread/archive` below would instead fail
        // with codex's own `-32600 no rollout found for thread id <id>`, a message that names
        // a symptom of codex's internals rather than a cause anyone reading it can act on.
        // `historyMode` (`CodexAdapter.historyMode`) already pins `legacy` on codex builds new
        // enough to accept it, which is why this should never actually fire on a supported
        // install — it exists to report the next contract change by name, rather than as
        // another opaque `-32600`.
        // The two branches below read `historyMode` rather than the probed codex version
        // (which this adapter does not hold) because they say genuinely different things: a
        // `nil` codex was sent no pin at all and may simply be too old to have one; a
        // `"legacy"` codex was asked for the contract explicitly and still did not honor it.
        guard let path = thread["path"] as? String, rolloutExists(URL(fileURLWithPath: path))
        else {
            throw AgentLaunchError.prepareFailed(historyMode == nil
                ? "this Codex build did not persist the new thread's history, and Flight "
                    + "Deck sent it no history-mode pin because it predates the 0.151.0 "
                    + "threshold that pin needs — try codex-cli 0.151.0 or newer."
                : "this Codex build did not persist the new thread's history even though "
                    + "Flight Deck asked it for the legacy history contract — it may no "
                    + "longer honor that pin. Try a codex-cli version Flight Deck supports.")
        }

        // Release the writer lock `thread/start` just took, or `codex resume <id>` — what
        // `launchCommand` spawns next, in its own pty — refuses on codex-cli 0.148.0 with
        // `thread/resume failed: thread <id> already has an active writer (code -32600)`.
        // Re-verified on 0.151.0: a second connection resuming an unarchived thread still
        // gets the same refusal, so this release is still required under `legacy` history.
        // This app-server is the one long-lived process that created the thread, and it
        // cannot simply be stopped: a thread belongs to the process that created it, and
        // this same process is also what renames it and reads its status later.
        //
        // `thread/unsubscribe` looks like the obvious release and is NOT one — probed
        // directly against a live app-server: it answers `{"status":"unsubscribed"}` while
        // the thread stays in `thread/loaded/list` and the lock stays held. What actually
        // works, also probed directly: `thread/archive` followed by `thread/unarchive` on
        // the same connection unloads the thread (`thread/loaded/list` goes from `[<id>]`
        // to `[]`) and releases the lock, and a real `codex resume` TUI then attaches with
        // this app-server still alive. The round trip is otherwise inert: it writes nothing
        // to `session_index.jsonl` (so `CodexNameWatcher` sees no spurious title event), and
        // `thread/name/set`/`thread/read` still succeed here afterward even while the TUI
        // holds the thread as writer — so `rename` and `read`/`rebind` need no change.
        //
        // A failure between these two calls must still propagate, same reasoning as the
        // naming commit above — but here the failure mode is worse than "no tab": if
        // `thread/archive` succeeds and `thread/unarchive` then fails, the thread is left
        // archived, and codex refuses to resume it at all ("session is archived. Run `codex
        // unarchive <id>`") rather than merely refusing while the lock is held. Swallowing
        // that and returning success anyway would hide it behind a tab that looks bound and
        // then can never launch, which is strictly harder to diagnose than today's lock
        // error. So this throws rather than catches, exactly like the naming commit: a
        // caller that sees `prepare` fail here knows to retry or fall back, rather than
        // discovering the break only when the terminal reports it.
        _ = try await rpc.request("thread/archive", ["threadId": raw])
        _ = try await rpc.request("thread/unarchive", ["threadId": raw])

        return AgentBinding(
            conversationID: id,
            transcriptURL: (thread["path"] as? String).map { URL(fileURLWithPath: $0) }
        )
    }

    /// The only case this serves for codex is identity ALREADY settled — a tab restored
    /// from a snapshot. Codex cannot mint an id locally, so unlike claude this never
    /// negotiates anything; it reads straight off what the store already holds and must
    /// not touch the app-server (a restore that happens before any process exists).
    func binding(for session: Session) -> AgentBinding {
        AgentBinding(
            conversationID: session.pinnedConversationID,
            transcriptURL: session.transcriptPath.map { URL(fileURLWithPath: $0) }
        )
    }

    func location(for session: Session) -> AgentLocation {
        // `prepare` passes transcriptDirectory as codex's own thread cwd via
        // `asThreadStartParams(cwd:historyMode:)`, and `launchCommand` requires the pty to be
        // spawned there.
        AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
    }

    /// Launch and resume are the same command: the thread already exists by the time any
    /// terminal opens, so there is no "first run" to distinguish.
    ///
    /// The caller MUST spawn this with the pty's cwd set to the thread's own cwd. Codex
    /// otherwise opens a "Choose working directory" picker that blocks the session behind a
    /// prompt with one sane answer.
    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        "codex resume \(binding.conversationID.uuidString.lowercased())\n"
    }

    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        launchCommand(binding, session, options)
    }

    /// Authoritative title and status for an already-bound thread.
    ///
    /// Used by `rebind` on every restore, and directly by `resumeRestoredCodex`'s follow-up
    /// title read: a session whose codex sat behind the directory-trust or hooks-review
    /// prompt emits nothing until the user clears it, so its title is stale by exactly one
    /// read rather than by a stream of missed notifications.
    ///
    /// Bounded by `readTimeout` rather than left to `CodexRPC.request`, which has no deadline
    /// at all. An app-server that answered `initialize` and then went quiet would otherwise
    /// leave a restored tab suspended here forever, waiting for a resume command that never
    /// gets typed. Same shape as `CodexProcessTransport.verifyHandshake`, and for the same
    /// reason.
    func read(_ binding: AgentBinding) async throws -> (title: String?, activity: SessionActivity?) {
        let rpc = self.rpc
        let threadID = binding.conversationID.uuidString.lowercased()
        let seconds = readTimeout
        return try await withThrowingTaskGroup(of: (String?, SessionActivity?).self) { group in
            group.addTask { @MainActor in
                let result = try await rpc.request("thread/read", ["threadId": threadID])
                let thread = result["thread"] as? [String: Any] ?? [:]
                // The same table `CodexThreadStatus` centralizes everywhere else — it exists
                // because two copies of this mapping once drifted, and the copy that used to
                // live here reported a *working* thread as idle on every reconcile.
                return (
                    thread["name"] as? String,
                    CodexThreadStatus.activity(from: thread["status"] as? [String: Any])
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CodexRPCError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CodexRPCError.timeout }
            return (title: first.0, activity: first.1)
        }
    }

    /// Re-attaches a restored tab to its thread, starting a fresh one if that thread is gone.
    ///
    /// The codex counterpart of `claude --resume <id> || claude --session-id <id>`: a thread
    /// the user archived or deleted between launches must not strand the tab. The caller
    /// re-pins `pinnedConversationID` when the returned id differs.
    ///
    /// Only a refusal that specifically means "no such thread" counts as gone. A timeout, a
    /// closed transport, a malformed request, an unknown method — none of those say anything
    /// about whether the thread exists, and starting a fresh one on that evidence would
    /// re-pin the tab away from the user's real conversation onto an empty one. That is a
    /// worse loss than the one this method exists to prevent, and an unrecoverable one,
    /// because the pin is what remembered where the conversation was. Everything else
    /// propagates, and the caller degrades to the thread it already had.
    func rebind(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        let threadID = session.pinnedConversationID.uuidString.lowercased()
        let existing = AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        do {
            _ = try await read(existing)
        } catch CodexRPCError.remote(_, let message)
            where Self.isThreadGone(message: message, threadID: threadID) {
            return try await prepare(for: session, options: options)
        }
        return AgentBinding(
            conversationID: session.pinnedConversationID,
            transcriptURL: session.transcriptPath.map { URL(fileURLWithPath: $0) }
        )
    }

    /// Whether a remote error about `threadID` means that thread is GONE, as opposed to
    /// merely refused, malformed or unimplemented.
    ///
    /// This used to be "any `.remote` error at all", which swept up `-32601 method not
    /// found`, `-32602 invalid params`, `-32600 invalid request` and every future
    /// "busy / locked / needs migration" — each of which would have re-pinned the tab onto a
    /// brand-new empty thread and thrown away the pin that remembered where the real
    /// conversation was.
    ///
    /// Establishing the actual signal took a live probe, because the schema does not carry
    /// error semantics, and the answer is not what the JSON-RPC spec would suggest. At
    /// codex-cli 0.147.0, `codex app-server` answers **`-32600` for everything**:
    ///
    ///     thread/read     on a thread that does not exist -> -32600 "thread not loaded: <id>"
    ///     thread/name/set on a thread that does not exist -> -32600 "no rollout found for thread id <id>"
    ///     an unknown method                              -> -32600 "Invalid request: unknown variant `x`"
    ///     a missing required param                       -> -32600 "Invalid request: missing field `threadId`"
    ///
    /// So the code discriminates nothing, and excluding the JSON-RPC reserved range — the
    /// obvious defensive move — would have disabled the gone-detection entirely. The signal
    /// that does discriminate is the message naming the thread we asked about: a protocol
    /// error never echoes the id, and an error about a specific thread always does. Both
    /// conditions are required, so neither a generic failure nor an unrelated message
    /// mentioning a uuid can be read as "gone".
    ///
    /// "thread not loaded" reads like a transient state and is not one. Probed directly: a
    /// thread that exists on disk but is not open in this app-server process answers
    /// `thread/read` **successfully**, with `status.type == "notLoaded"`. Only a thread with
    /// no rollout at all produces the error form.
    /// Takes no error code on purpose: see above, codex answers `-32600` for every one of
    /// these, so the code carries no information to key on.
    static func isThreadGone(message: String, threadID: String) -> Bool {
        let text = message.lowercased()
        guard text.contains(threadID.lowercased()) else { return false }
        return ["not loaded", "no rollout", "not found", "no such thread"]
            .contains { text.contains($0) }
    }

    func rename(_ binding: AgentBinding, to title: String) async throws {
        _ = try await rpc.request("thread/name/set", [
            "threadId": binding.conversationID.uuidString.lowercased(),
            "name": title,
        ])
    }

    /// Codex has its own shell-level login subcommand, so signing in is one command with
    /// nothing to type afterward — unlike claude, which has to be launched and then told
    /// `/login` from inside a running session.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation {
        LoginInvocation(command: "codex login", inject: nil)
    }

    /// A claude payload here is a programming error, not a runtime condition: the store
    /// picks the adapter and the options together. Degrade to defaults rather than trap.
    private func threadOptions(_ options: AgentOptions) -> CodexThreadOptions {
        if case .codex(let o) = options { return o }
        return CodexThreadOptions()
    }
}
