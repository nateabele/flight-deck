import Foundation

/// What a Claude session is doing. Raw values match the `status` field written by `claude`
/// to `~/.claude/sessions/<pid>.json` — except `shell`, which is not an activity at all:
/// `claude` writes it for `idle && hasBackgroundTasks`, and `ClaudeStatusFile.decode` splits
/// it into `.idle` plus `Entry.reportsBackgroundWork`. See `SessionStore.backgroundWorkSessions`.
enum SessionActivity: String, Equatable {
    case idle, busy, waiting
}

extension SessionActivity {
    /// Priority when several children collapse into one glyph on a project header.
    /// Higher wins. Idle sits at the bottom and is filtered out before this is consulted,
    /// but it is ranked anyway so the ordering is total and the tests can state it.
    ///
    /// The order is by how much the state wants you: a blocked prompt outranks work that
    /// is simply in progress.
    var summaryRank: Int {
        switch self {
        case .idle: return 0
        case .busy: return 1
        case .waiting: return 2
        }
    }
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
    /// This Mac's own verdict that `waitingFor` is describing nothing a person can act on.
    ///
    /// `claude`'s own background-Task-subagent status reporting has no distinct value for
    /// "foreground idle while a background Task subagent runs" — unlike `"shell"`, which it
    /// does use for idle-with-background-bash — so it flips to `waiting` / `"input needed"`
    /// with no `AskUserQuestion` or permission call open anywhere in the transcript tail.
    /// `SessionStore.derivedOpenPromptCalls` is what notices: the same continuous-unnameable
    /// episode `checkStuckPrompts` already tracked for its own log (`stuckPromptEpisodes`),
    /// debounced the same way, so an ordinary race between the status file and the transcript
    /// (a beat of "unnamed" before the record naming the real call lands) never sets this.
    ///
    /// Only ever true alongside `activity == .waiting`, and only for the specific refusal
    /// `"prompt_changed"` — a build that cannot even ask (`"unsupported_agent"`, codex today)
    /// is a Mac that might be looking at a real dialog it simply cannot read, which is a
    /// different sentence and keeps the existing "Waiting for you" wording.
    var answerless: Bool

    init(
        activity: SessionActivity, waitingFor: String? = nil, subagentCount: Int = 0,
        answerless: Bool = false
    ) {
        self.activity = activity
        self.waitingFor = waitingFor
        self.subagentCount = subagentCount
        self.answerless = answerless
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
            // Wins over `waitingFor` either way — a `waiting` tab this Mac has confirmed
            // nothing is open under is never worth the reason `claude` gave for it, because
            // that reason is precisely the string this field exists to stop repeating.
            guard !answerless else { return "Still working (no response needed)" }
            guard let waitingFor, !waitingFor.isEmpty else { return "Waiting for you" }
            return "Waiting for you — \(waitingFor)"
        }
    }

    /// Tooltip and accessibility label for a row that may carry the unread dot, and
    /// optionally the background-work badge.
    ///
    /// The unread state is drawn with colour alone (a filled dot in the accent colour rather
    /// than grey), so this string is what carries the same distinction for VoiceOver and for
    /// anyone who cannot separate the two hues — the HIG's "don't rely on colour alone" rule
    /// is satisfied through this channel rather than through a second glyph shape.
    ///
    /// Additive rather than a change to `tooltip`: notification bodies use that one and have
    /// no notion of read state.
    ///
    /// `backgroundWork` defaults to `false` rather than existing as a separate one-parameter
    /// overload, so every call site written as `tooltip(unread:)` before the flag existed
    /// still compiles AND still runs through this one implementation — a duplicate overload
    /// here previously let such a call site silently bind to dead code instead.
    /// The background clause it appends is never substituted, and always last. Every string
    /// this produced before the flag existed is unchanged when `backgroundWork` is false —
    /// which is what lets `SessionStatusGlyph.label(for:)` on iOS pin the same literals.
    func tooltip(unread: Bool, backgroundWork: Bool = false) -> String {
        let base = unread && activity == .idle ? "Finished — not yet viewed" : tooltip
        guard backgroundWork else { return base }
        return base + " — background command running"
    }
}
