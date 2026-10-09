import Foundation

/// grok's activity, folded from the two files it writes per session. Pure, so every rule is a
/// fixture test with no process and no clock.
///
/// **Ruling: status comes from `events.jsonl`, not from a hook.** grok's hooks would also do
/// (they fire in the TUI and inherit the tab's environment), but the TUI has no per-session hook
/// injection — `--plugin-dir` is rejected and `GROK_CONFIG` ignores `hooks` (facts §0.2) — so
/// the only route is a file in `$GROK_HOME/hooks/`, a change to the user's own grok config that
/// shows in `/hooks` and outlives Flight Deck. `events.jsonl` needs nothing installed, is
/// written sub-second, and carries every transition the hooks would (probed, grok 1.0.30):
///
/// - `turn_started` … `turn_ended{outcome}` brackets a turn (`completed` or `cancelled`);
/// - `permission_requested{tool_name}` / `permission_resolved{decision}` bracket a card.
///   **They carry no call id, so they are COUNTED.** grok raises several in the same
///   millisecond for parallel tools, and auto-allowed tools emit the pair back to back with
///   `wait_ms: 0` — so "a permission phase" alone is not a card; an unmatched request is.
/// - everything else inside a turn (`phase_changed`, `tool_started`, `first_token`, …) is proof
///   the turn is running, which matters for a tab attached mid-turn that never saw its start.
///
/// The one blocking surface `events.jsonl` does NOT mark is a question card: `ask_user_question`
/// is auto-allowed and then simply runs until answered. That comes from `updates.jsonl` — an
/// `ask_user_question` `tool_call` with no terminal `tool_call_update`.
struct GrokStatusFold: Equatable {
    private(set) var turnActive = false
    private(set) var pendingPermissions = 0
    private(set) var openQuestions: Set<String> = []
    /// Running subagents holding a permission card. Their cards are drawn in this session's TUI
    /// but marked only in their own `events.jsonl` (facts-2 §4) — a foreground subagent's parent
    /// reads `busy` throughout — so the watcher counts them and sets this; turn records here
    /// never clear it, because a background child outlives its parent's turn.
    private(set) var childPermissions = 0

    var activity: SessionActivity {
        if pendingPermissions > 0 || !openQuestions.isEmpty || childPermissions > 0 { return .waiting }
        return turnActive ? .busy : .idle
    }

    mutating func apply(childPermissions count: Int) {
        childPermissions = max(0, count)
    }

    /// One `events.jsonl` record. Returns the discrete events it implies beyond the activity
    /// change the caller derives from `activity`.
    mutating func apply(eventRecord record: [String: Any]) -> [AgentEvent] {
        guard let type = record["type"] as? String else { return [] }
        return apply(eventType: type, outcome: record["outcome"] as? String)
    }

    /// The same rule over the two fields it reads, which is what `GrokScan` carries off the
    /// background queue instead of a whole decoded record.
    mutating func apply(eventType type: String, outcome: String?) -> [AgentEvent] {
        switch type {
        case "turn_started":
            turnActive = true
            pendingPermissions = 0
            return []
        case "permission_requested":
            turnActive = true
            pendingPermissions += 1
            return []
        case "permission_resolved":
            pendingPermissions = max(0, pendingPermissions - 1)
            return []
        case "turn_ended":
            turnActive = false
            pendingPermissions = 0
            openQuestions.removeAll()
            // A cancelled turn is the user stopping it (Ctrl+C, or rejecting a permission card,
            // which grok also ends the turn on) — what `.turnAborted` exists to say, so the
            // auto-retry loop never types into a tab its owner just stopped.
            if outcome == "cancelled" { return [.turnEnded, .turnAborted] }
            return [.turnEnded]
        case "phase_changed", "tool_started", "tool_completed", "loop_started", "first_token":
            turnActive = true
            return []
        default:
            // `mcp_*` and the rest are session bookkeeping, written at launch as well as
            // mid-turn, so they say nothing about whether a turn is running.
            return []
        }
    }

    /// What an `updates.jsonl` record says about a question card, reduced to a `Sendable`
    /// value so `GrokScan` can decode off the main actor.
    enum QuestionSignal: Equatable, Sendable {
        case opened(String)
        case closed(String)
        case turnCompleted
    }

    static func questionSignal(inUpdateRecord record: [String: Any]) -> QuestionSignal? {
        guard let params = record["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String
        else { return nil }
        switch kind {
        case "tool_call":
            guard GrokTimelineMapper.toolName(update) == GrokTimelineMapper.questionTool,
                  let id = update["toolCallId"] as? String else { return nil }
            return .opened(id)
        case "tool_call_update":
            guard let id = update["toolCallId"] as? String,
                  let status = update["status"] as? String, status == "completed" || status == "failed"
            else { return nil }
            return .closed(id)
        case "turn_completed":
            return .turnCompleted
        default:
            return nil
        }
    }

    /// One `updates.jsonl` record: only the question card's open and close.
    mutating func apply(updateRecord record: [String: Any]) {
        if let signal = Self.questionSignal(inUpdateRecord: record) { apply(signal) }
    }

    mutating func apply(_ signal: QuestionSignal) {
        switch signal {
        case .opened(let id): openQuestions.insert(id)
        case .closed(let id): openQuestions.remove(id)
        case .turnCompleted: openQuestions.removeAll()
        }
    }
}
