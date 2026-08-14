import Foundation

/// What a Claude session is doing. Raw values match the `status` field written by
/// `claude` to `~/.claude/sessions/<pid>.json`.
///
/// `shell` is the non-obvious one: the model turn has finished but a backgrounded
/// Bash task is still running, so the session is neither working nor done.
enum SessionActivity: String, Equatable {
    case idle, busy, waiting, shell
}

/// A session's activity plus the detail the sidebar needs to describe it.
/// Absence of a status is represented by `nil` at the call site, not by a case —
/// "no `claude` running" renders nothing, which is distinct from `idle`.
struct SessionStatus: Equatable {
    var activity: SessionActivity
    /// Why the session is blocked, when `activity == .waiting`. Values come from
    /// `claude` verbatim: "permission prompt", "input needed", "dialog open", …
    var waitingFor: String?
    /// Outstanding top-level `Agent` tool calls. Only meaningful while `busy`.
    var subagentCount: Int

    init(activity: SessionActivity, waitingFor: String? = nil, subagentCount: Int = 0) {
        self.activity = activity
        self.waitingFor = waitingFor
        self.subagentCount = subagentCount
    }

    /// Tooltip and accessibility label. Kept on the model rather than in the view so
    /// it is testable without instantiating SwiftUI.
    var tooltip: String {
        switch activity {
        case .idle:
            return "Idle"
        case .busy:
            guard subagentCount > 0 else { return "Working" }
            let noun = subagentCount == 1 ? "subagent" : "subagents"
            return "Working — \(subagentCount) \(noun)"
        case .waiting:
            guard let waitingFor, !waitingFor.isEmpty else { return "Waiting for you" }
            return "Waiting for you — \(waitingFor)"
        case .shell:
            return "Background command running"
        }
    }

    /// Tooltip and accessibility label for a row that may carry the unread dot.
    ///
    /// The unread state is drawn with colour alone (a filled dot in the accent colour rather
    /// than grey), so this string is what carries the same distinction for VoiceOver and for
    /// anyone who cannot separate the two hues — the HIG's "don't rely on colour alone" rule
    /// is satisfied through this channel rather than through a second glyph shape.
    ///
    /// Additive rather than a change to `tooltip`: notification bodies use that one and have
    /// no notion of read state.
    func tooltip(unread: Bool) -> String {
        guard unread, activity == .idle else { return tooltip }
        return "Finished — not yet viewed"
    }
}
