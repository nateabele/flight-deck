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
    /// independent: a resume can change the conversation, the directory, or both.
    struct Resolution: Equatable {
        /// nil means the anchor was lost — no live process is ours.
        var anchor: Anchor?
        var conversationID: UUID
        /// The directory `claude` reports it is running in, echoed back unchanged when the
        /// row omits it. Reported, not interpreted: this resolver says where the process is,
        /// and `SessionStore.applyRegistry` decides separately what that means for the
        /// transcript the tab watches and for the project it is filed under — a worktree cwd
        /// moves the first and deliberately not the second.
        var workingDirectory: String
    }

    /// Match by conversation while unanchored; follow the pid once anchored.
    ///
    /// Match-by-conversation is the one ambiguous operation, and its guarantee is
    /// **conditional, not universal**. It is unambiguous exactly while the pin is a UUID
    /// Flight Deck generated and passed as `--session-id` — no other `claude` on the
    /// machine can be running a conversation whose id we invented — which covers a tab's
    /// whole life up to its first resume, and is why the first anchoring is sound. Every
    /// lookup after that is by pid, which is immune to the conversation changing
    /// underneath us, and that change is precisely the event we are detecting.
    ///
    /// The guarantee stops holding after a resume: this branch runs whenever the tab has
    /// no anchor, including re-anchoring once the anchored `claude` exits, and by then the
    /// pin may name a conversation the user could equally open in a plain terminal (or one
    /// rehydrated by `SessionStore.restore()` after a relaunch). Accepted, not overlooked —
    /// the failure needs a dead tab process plus a deliberate resume of that exact
    /// conversation elsewhere, and its symptom is a wrong status icon, not lost state. See
    /// `docs/superpowers/specs/2026-08-11-resumed-conversation-pinning-design.md` §5.
    ///
    /// - Parameter workingDirectory: the caller's fallback for a row that reports an empty
    ///   `cwd`, echoed straight back in that case. Pass the tab's **`transcriptDirectory`**,
    ///   never its `workingDirectory` — what comes back feeds `ClaudeSession.transcriptURL`,
    ///   so falling back to the project would move a worktree session's watcher onto the
    ///   project's transcript the first time a row omitted its cwd. The name is inherited
    ///   from before the two fields split and is misleading here; renaming it is deferred in
    ///   `docs/FOLLOWUPS.md`.
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
