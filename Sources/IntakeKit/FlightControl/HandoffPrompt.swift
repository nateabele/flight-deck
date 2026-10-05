import Foundation

/// The first prompt a hand-off agent gets (L3-U §5.5). Nothing else is migrated: the new agent
/// learns what happened only from this text, the transcript it points at, and the repo — so
/// every line is an instruction it can act on.
public enum HandoffPrompt {
    public static func render(_ r: HandoffRequest) -> String {
        var lines = ["You are continuing task \(r.task.id), started by \(r.oldAgent), which stopped because its account reached its usage limit."]
        if let t = r.transcript {
            switch t.locator {
            case .path(let path):
                lines.append("Its transcript is at \(path) (\(t.format)). Read it to understand what was done and decided.")
            case .command(let command):
                lines.append("Its transcript is available from `\(command)` (\(t.format)). Read it to understand what was done and decided.")
            }
            if !t.howToRead.isEmpty { lines.append(t.howToRead) }
        } else {
            // §7: the hand-off still runs; the prompt says so and points at what is left.
            lines.append("Its transcript is not available. Lean on `git diff` and the task's notes in `br show \(r.task.id)` to understand what was done and decided.")
        }
        lines.append("Run `git status` and `git diff` before changing anything. The work may be half done.")
        if r.reservedFiles.isEmpty {
            lines.append("It held no file reservations. Reserve the files you will edit with Agent Mail before you edit them.")
        } else {
            lines.append("Re-reserve these files before editing: \(r.reservedFiles.joined(separator: ", ")).")
        }
        lines.append("Then finish the task as described in `br show \(r.task.id)`.")
        return lines.joined(separator: "\n")
    }
}

/// The real `HandoffPlanner` (L3-0): a swarm agent gets a request exactly when the account its
/// lease names is over hard in that lease's pool.
///
/// The transcript and reservation lookups are injected because both live app-side (adapter
/// capabilities, Agent Mail). They are `@Sendable` to satisfy the contract; the app's closures
/// hop with `MainActor.assumeIsolated`, which holds because the hand-off driver calls this from
/// the main actor.
public final class LedgerHandoffPlanner: HandoffPlanner, @unchecked Sendable {
    private let reader: CapacityReader
    private let transcript: @Sendable (SessionRef) -> TranscriptPointer?
    private let reservedFiles: @Sendable (SwarmAgentSnapshot) -> [String]

    public init(reader: CapacityReader,
                transcript: @escaping @Sendable (SessionRef) -> TranscriptPointer?,
                reservedFiles: @escaping @Sendable (SwarmAgentSnapshot) -> [String]) {
        self.reader = reader; self.transcript = transcript; self.reservedFiles = reservedFiles
    }

    public func request(for agent: SwarmAgentSnapshot) -> HandoffRequest? {
        // A slot lease (`id == nil`) is a local pool's concurrency, never quota.
        guard let lease = agent.lease, let accountID = lease.account.id, let task = agent.task else { return nil }
        // By id and harness, not the whole `AccountRef`: its label is display text and changes
        // on rename.
        let mine = reader.headroom(pool: lease.pool).first {
            $0.account.id == accountID && $0.account.harness == lease.account.harness
        }
        guard mine?.state == .overHard else { return nil }
        return HandoffRequest(task: task, block: agent.block, oldAgent: agent.agentName, oldSession: agent.session,
                              transcript: transcript(agent.session), reservedFiles: reservedFiles(agent),
                              fromAccount: lease.account)
    }
}
