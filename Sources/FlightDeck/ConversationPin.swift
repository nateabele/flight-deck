import Foundation

/// Which Claude conversation a tab is attached to, and how that is worked out from the
/// `~/.claude/sessions/<pid>.json` registry.
///
/// Pure and stateless so every rule is unit-testable; `SessionStore` applies the results.
/// See `docs/superpowers/specs/2026-08-11-resumed-conversation-pinning-design.md` §5.
enum ConversationPin {
    /// One `claude` process. `pid` alone is not an identity — macOS recycles pids — so it
    /// is always paired with the process start time the registry reports.
    struct Anchor: Equatable {
        let pid: pid_t
        let procStart: String
    }

    /// What a tab should look like after reconciling against the registry. Each field is
    /// independent: a resume can change the conversation, the project, or both.
    struct Resolution: Equatable {
        /// nil means the anchor was lost — no live process is ours.
        var anchor: Anchor?
        var conversationID: UUID
        var workingDirectory: String
    }

    /// Anchor once by conversation, then follow the pid forever.
    ///
    /// The ordering is what makes this sound. A tab can only be anchored while its
    /// conversation id is one Flight Deck generated and passed as `--session-id`, so at
    /// that moment at most one row can plausibly be ours. Every later lookup is by pid,
    /// which is immune to the conversation changing underneath us — and the conversation
    /// changing underneath us is precisely the event we are trying to detect.
    static func resolve(
        conversationID: UUID,
        workingDirectory: String,
        anchor: Anchor?,
        rows: [pid_t: ClaudeStatusFile.Entry]
    ) -> Resolution {
        let unchanged = Resolution(
            anchor: nil, conversationID: conversationID, workingDirectory: workingDirectory
        )

        if let anchor {
            // A row under our pid whose process start time differs is a *different*
            // process that inherited a recycled pid, not our session resuming.
            guard let row = rows[anchor.pid], row.procStart == anchor.procStart else {
                return unchanged
            }
            return Resolution(
                anchor: anchor,
                conversationID: row.sessionID,
                workingDirectory: row.cwd.isEmpty ? workingDirectory : row.cwd
            )
        }

        // Newest process wins, with pid as a tiebreak purely so the choice is
        // deterministic: `rows.values` has no defined order, and two processes really can
        // hold one conversation once resumes are in play.
        let candidates = rows.values.filter { $0.sessionID == conversationID }
        guard let row = candidates.max(by: { lhs, rhs in
            (lhs.startedAt, lhs.pid) < (rhs.startedAt, rhs.pid)
        }) else { return unchanged }

        return Resolution(
            anchor: Anchor(pid: row.pid, procStart: row.procStart),
            conversationID: row.sessionID,
            workingDirectory: row.cwd.isEmpty ? workingDirectory : row.cwd
        )
    }

    /// Tabs sharing a conversation with another tab, as tab ids.
    ///
    /// Derived from the whole list on every read rather than recorded at resume time, so
    /// it also covers a restored snapshot that already holds a duplicate and two tabs that
    /// collide in either order.
    static func conflicted(_ sessions: [Session]) -> Set<UUID> {
        let groups = Dictionary(grouping: sessions, by: \.pinnedConversationID)
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }
}
