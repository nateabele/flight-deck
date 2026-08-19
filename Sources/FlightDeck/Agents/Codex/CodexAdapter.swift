import Foundation

/// Codex conformance, driven over `codex app-server` JSON-RPC rather than by typing at a pty.
///
/// The inversion versus claude is deliberate and forced by the tool: codex assigns thread
/// ids itself, so identity is *returned* rather than minted. What matters is that it is
/// still known before a terminal exists, which is the property the rest of the app relies on.
@MainActor
struct CodexAdapter: AgentAdapter {
    static let id: AgentID = .codex

    let rpc: CodexRPC

    /// Deadline for `read`, in seconds. `CodexRPC.request` has none of its own — only the
    /// handshake verifier produces `.timeout` — and `read` is the one call a *restored* tab
    /// waits on before anything can be typed at it. A property rather than an argument so it
    /// stays out of the `AgentAdapter.rebind` signature, which is not codex's to shape.
    var readTimeout: Double = 5

    /// Start, then name. NOT optional and NOT reorderable.
    ///
    /// `thread/start` does not persist anything: no `threads` row, no rollout file, even
    /// with the app-server left alive. `thread/name/set` — issued to the same app-server
    /// process — commits it. Skip the name and `codex resume <id>` dies with
    /// `ERROR: No saved session found with ID …`, which is a tab that can never launch.
    /// Naming costs nothing anyway: the tab already has the title we want to set.
    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        let params = threadOptions(options).asThreadStartParams(cwd: session.transcriptDirectory)
        let result = try await rpc.request("thread/start", params)

        guard let thread = result["thread"] as? [String: Any],
              let raw = thread["id"] as? String,
              let id = UUID(uuidString: raw)
        else { throw CodexRPCError.malformed("thread/start returned no usable thread id") }

        // Commit. A failure here must propagate: a bound-but-uncommitted thread is worse
        // than no tab, because it looks fine until the terminal reports it cannot resume.
        _ = try await rpc.request("thread/name/set", ["threadId": raw, "name": session.title])

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
    /// Used by reconcile-on-first-contact: a session whose codex sat behind the
    /// directory-trust or hooks-review prompt emits nothing until the user clears it, so its
    /// title is stale by exactly one read rather than by a stream of missed notifications.
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
                // Same table the notification path uses — `CodexThreadStatus` exists because
                // these two drifted, and the copy that lived here reported a *working*
                // thread as idle on every reconcile.
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
    /// Only a *refusal* means gone. A timeout or a closed transport says nothing about
    /// whether the thread exists, and starting a fresh one on that evidence would re-pin the
    /// tab away from the user's real conversation onto an empty one — a worse loss than the
    /// one this method exists to prevent, and an unrecoverable one, because the pin is what
    /// remembered where the conversation was. Those propagate instead, and the caller
    /// degrades to the thread it already had.
    func rebind(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        let existing = AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        do {
            _ = try await read(existing)
        } catch CodexRPCError.remote(_, _) {
            return try await prepare(for: session, options: options)
        }
        return AgentBinding(
            conversationID: session.pinnedConversationID,
            transcriptURL: session.transcriptPath.map { URL(fileURLWithPath: $0) }
        )
    }

    func rename(_ binding: AgentBinding, to title: String) async throws {
        _ = try await rpc.request("thread/name/set", [
            "threadId": binding.conversationID.uuidString.lowercased(),
            "name": title,
        ])
    }

    /// A claude payload here is a programming error, not a runtime condition: the store
    /// picks the adapter and the options together. Degrade to defaults rather than trap.
    private func threadOptions(_ options: AgentOptions) -> CodexThreadOptions {
        if case .codex(let o) = options { return o }
        return CodexThreadOptions()
    }
}
