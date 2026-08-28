import Foundation

extension WireSession {
    /// How many sub-agents this session is running, said out loud — or `nil` when nobody
    /// knows, which is not the same as zero.
    ///
    /// **The spec has this asymmetry backwards, and the difference is a claim about the
    /// world.** §6 says "a count for claude, per-sub-agent for codex". In fact
    /// `TranscriptWatcher` maintains a real count of claude's outstanding top-level `Agent`
    /// tool calls, while `CodexEventMapper`'s doc comment records that no `collab` record
    /// exists in any of 492 surveyed rollouts and that `subagentCount` is *deliberately never
    /// emitted for codex*. Re-checked across 494 rollouts: still nothing.
    ///
    /// So a codex tab's `subagentCount` is always `0`, and `0` there means **unknown**.
    /// Rendering "0 subagents" would assert that none are running, which nobody has any
    /// grounds to say. Silence is the honest answer, and it is the same answer an agent this
    /// build has never heard of gets — `agent` is a `String` precisely so a newer Mac's agent
    /// degrades to "renders without a glyph" rather than taking the snapshot down, and
    /// inventing a count for it would be the same mistake.
    ///
    /// One implementation, shared by the list's status glyph and the timeline's header, so
    /// the two screens cannot come to different conclusions about the same session.
    public var subagentSummary: String? {
        // Only claude has ground truth here. Add an agent to this list when — and only
        // when — something actually emits a count for it.
        guard agent == "claude", subagentCount > 0 else { return nil }
        return "\(subagentCount) subagent\(subagentCount == 1 ? "" : "s")"
    }
}
