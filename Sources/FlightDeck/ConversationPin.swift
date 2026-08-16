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
    ///
    /// The two directory fields are **not** two names for one value, and conflating them is
    /// a live bug rather than a tidiness question. `transcriptDirectory` is always safe to
    /// use — it falls back to what the caller passed in — while `reportedDirectory` is the
    /// only one that constitutes *evidence about where `claude` is*. A caller that treats
    /// the echoed fallback as evidence acts on a tick where nothing was reported at all.
    struct Resolution: Equatable {
        /// nil means the anchor was lost — no live process is ours.
        var anchor: Anchor?
        var conversationID: UUID
        /// The directory a registry row actually named, or nil when none did: no row matched
        /// this tab, or the row it matched carried an empty `cwd`. An empty `cwd` is folded
        /// in here rather than passed on, because the registry omitting a directory is the
        /// registry saying nothing, not saying "somewhere new".
        ///
        /// Use this, not `transcriptDirectory`, for any decision that must only fire on new
        /// information — filing the tab under a different project above all. `SessionStore`
        /// passes the tab's own transcript directory as the fallback below, so on a quiet
        /// tick `transcriptDirectory` comes back *equal to a value the tab already holds*
        /// and looks exactly like a report of it.
        var reportedDirectory: String?
        /// Where the tab's transcript is: `reportedDirectory` when a row named one, else the
        /// caller's fallback echoed back unchanged so the watcher simply stays put. Safe on
        /// any tick, evidence on none.
        var transcriptDirectory: String
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
    /// - Parameter transcriptDirectory: the tab's current transcript directory, echoed back
    ///   as `Resolution.transcriptDirectory` whenever no row names one. Pass the tab's
    ///   `transcriptDirectory`, never its `workingDirectory` — what comes back feeds
    ///   `ClaudeSession.transcriptURL`, so falling back to the project would move a worktree
    ///   session's watcher onto the project's transcript the first time a row omitted its
    ///   cwd. Because it is echoed, it is also why `reportedDirectory` exists separately:
    ///   the echo is indistinguishable from a report of the same path.
    static func resolve(
        conversationID: UUID,
        transcriptDirectory: String,
        anchor: Anchor?,
        rows: [pid_t: ClaudeStatusFile.Entry]
    ) -> Resolution {
        let unchanged = Resolution(
            anchor: nil,
            conversationID: conversationID,
            reportedDirectory: nil,
            transcriptDirectory: transcriptDirectory
        )

        if let anchor {
            // A row under our pid whose process start time differs is a *different*
            // process that inherited a recycled pid, not our session resuming.
            guard let row = rows[anchor.pid], row.procStart == anchor.procStart else {
                return unchanged
            }
            return resolution(anchor: anchor, row: row, fallback: transcriptDirectory)
        }

        // Newest process wins, with pid as a tiebreak purely so the choice is
        // deterministic: `rows.values` has no defined order, and two processes really can
        // hold one conversation once resumes are in play.
        let candidates = rows.values.filter { $0.sessionID == conversationID }
        guard let row = candidates.max(by: { lhs, rhs in
            (lhs.startedAt, lhs.pid) < (rhs.startedAt, rhs.pid)
        }) else { return unchanged }

        return resolution(
            anchor: Anchor(pid: row.pid, procStart: row.procStart),
            row: row,
            fallback: transcriptDirectory
        )
    }

    /// One matched row's contribution, shared by both branches so the empty-`cwd` rule
    /// cannot drift between them: an omitted directory becomes `nil` evidence *and* leaves
    /// the transcript where it was, in one place rather than two.
    private static func resolution(
        anchor: Anchor, row: ClaudeStatusFile.Entry, fallback: String
    ) -> Resolution {
        let reported = row.cwd.isEmpty ? nil : row.cwd
        return Resolution(
            anchor: anchor,
            conversationID: row.sessionID,
            reportedDirectory: reported,
            transcriptDirectory: reported ?? fallback
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
