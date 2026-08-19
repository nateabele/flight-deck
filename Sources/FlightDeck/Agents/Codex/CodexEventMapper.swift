import Foundation

/// Translates codex's rollout records into the app's own vocabulary.
///
/// Pure and static so every mapping is testable from a captured line with no process, no
/// socket and no timing — the same reason `ClaudeSession.events(inLine:sessionID:)` is pure.
///
/// This used to translate app-server notifications instead. That path was removed, not
/// deprecated: those notifications only ever reach the connection that made the change, so
/// none of them described anything a user did in a `codex resume` TUI.
enum CodexEventMapper {
    /// Translates one line of a codex rollout `.jsonl` into the app's vocabulary.
    ///
    /// This is the production path. Codex's app-server notifications are scoped to the
    /// connection that made the change, and turns run in a separate `codex resume` process,
    /// so nothing about what the user does ever reaches our connection. The rollout is
    /// written by whichever process drives the turn, which is exactly the property the
    /// notification route lacks.
    ///
    /// Only `event_msg` records carry turn boundaries. `response_item`, `turn_context`,
    /// `world_state` and `session_meta` are conversation content and bookkeeping.
    ///
    /// Two things this can never emit, both stated as limitations rather than approximated
    /// (spec §5):
    ///
    /// - **`.waiting`.** Codex writes nothing when it starts waiting on approval — verified
    ///   with an approval prompt live on screen, where the rollout's last record was a
    ///   `custom_tool_call` with no output and no `task_complete`. A codex tab therefore
    ///   reads busy through a prompt; `.waiting` is not derivable from this file.
    /// - **`.subagentCount`.** No `collab` record exists in any of 492 surveyed rollouts, so
    ///   there is no ground truth to map it from. Deliberately never emitted for codex.
    static func events(inRolloutLine line: String) -> [AgentEvent] {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let record = raw as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              let kind = payload["type"] as? String
        else { return [] }

        switch kind {
        case "task_started":
            return [.activity(.busy)]

        // `.turnEnded` is what `SessionReadPolicy` marks unread from, so it must accompany
        // idle. An aborted turn is still a turn that ended: the user interrupted it, and a
        // tab left spinning because nothing said "over" is the worse failure.
        case "task_complete", "turn_aborted":
            return [.activity(.idle), .turnEnded]

        default:
            return []
        }
    }
}
