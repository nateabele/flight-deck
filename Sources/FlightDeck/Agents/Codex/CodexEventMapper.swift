import FleetKit
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
    /// `task_complete` and `turn_aborted` used to share one arm — both just end the turn. They
    /// no longer do: `task_complete` can carry an `error` field (a turn that failed on an API
    /// error still "completes"), so it alone also emits `.apiError`. `turn_aborted` is a user
    /// interrupt, never an API failure, so it keeps the old two-event shape untouched.
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
        // idle. The error rides as a FIELD on this record rather than as a record type of its
        // own, which is why a survey of rollout `type` values finds nothing error-shaped.
        // Probed 2026-09-21 against codex-cli 0.155.1 by driving a real TUI at an upstream
        // returning 429. The app-server spells the same payload in camelCase; the file spells
        // it snake_case, and the file is what this parser reads.
        case "task_complete":
            guard let error = payload["error"] as? [String: Any] else {
                return [.activity(.idle), .turnEnded, .apiError(nil)]
            }
            return [.activity(.idle), .turnEnded, .apiError(apiError(fromTurnError: error))]

        // Split from `task_complete` rather than sharing its arm: an aborted turn is still a
        // turn that ended (the user interrupted it, and a tab left spinning because nothing
        // said "over" is the worse failure), but it is a user interrupt, not an API failure —
        // it must neither raise an error nor clear one that is standing.
        //
        // It does, however, have to be *reported* as an interrupt, which is what `.turnAborted`
        // is for: the auto-retry loop types into this tab unattended, and pressing Esc is how a
        // person stops that. Idle alone cannot carry it — an ordinary turn ending is idle too.
        //
        // `reason` is deliberately not read. The only value ever captured here is
        // `"interrupted"` (see `Fixtures/Codex/turn-aborted.captured.jsonl`), and this parser
        // has the same fail-safe direction as `CodexTurnRecovery`'s allowlist but pointed the
        // other way: treating an unfamiliar reason as an interrupt STOPS unattended typing,
        // where reading the field and not recognising a new value would keep it going.
        case "turn_aborted":
            return [.activity(.idle), .turnEnded, .turnAborted]

        default:
            return []
        }
    }

    /// `codex_error_info` is a union: a bare string for the unit variants (`"unauthorized"`),
    /// or a one-key object for the ones carrying a status
    /// (`{"response_too_many_failed_attempts":{"http_status_code":429}}`). Both shapes are in
    /// the published schema, so reading only one would drop half the vocabulary.
    private static func apiError(fromTurnError error: [String: Any]) -> SessionAPIError {
        let info = error["codex_error_info"]
        var kind: String?
        var status: Int?
        if let name = info as? String {
            kind = name
        } else if let object = info as? [String: Any], let name = object.keys.first {
            kind = name
            status = (object[name] as? [String: Any])?["http_status_code"] as? Int
        }
        return SessionAPIError(
            status: status,
            kind: kind,
            // One source of truth: the adapter's allowlist, so the persisted flag and the
            // retry decision cannot disagree.
            isTransient: CodexTurnRecovery.isTransientKind(kind))
    }
}
