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
