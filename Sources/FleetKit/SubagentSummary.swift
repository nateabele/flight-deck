import Foundation

extension WireSession {
    /// A positive runtime-supplied sub-agent count, or `nil` for zero or an unknown agent.
    /// Zero stays silent because it can also mean an older runtime supplied no count.
    ///
    /// One implementation, shared by the list's status glyph and the timeline's header, so
    /// the two screens cannot come to different conclusions about the same session.
    public var subagentSummary: String? {
        // Unknown agents stay silent until this build understands their count semantics.
        guard agent == "claude" || agent == "codex" || agent == "opencode",
              subagentCount > 0 else { return nil }
        return "\(subagentCount) subagent\(subagentCount == 1 ? "" : "s")"
    }
}
