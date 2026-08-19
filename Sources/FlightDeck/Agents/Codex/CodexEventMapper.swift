import Foundation

/// Per-thread state the mapper carries between notifications. Small on purpose: codex
/// pushes enough that almost nothing needs remembering.
struct CodexThreadState: Equatable {
    /// Last known state of each sub-agent, keyed by its thread id. Replaced wholesale from
    /// every `collabAgentToolCall.agentsStates`, never incremented.
    var subagents: [String: String] = [:]
}

/// Translates codex app-server notifications into the app's own vocabulary.
///
/// Pure and static so every mapping is testable from a recorded payload with no process,
/// no socket and no timing — the same reason `ClaudeSession.events(inLine:sessionID:)` is pure.
enum CodexEventMapper {
    /// `CollabAgentStatus` values that mean a sub-agent is still occupying a slot.
    ///
    /// The full union, from `CollabAgentStatus` in the schema emitted by
    /// `codex app-server generate-json-schema` at codex-cli 0.147.0:
    ///
    ///     pendingInit | running | interrupted | completed | errored | shutdown | notFound
    ///
    /// Of the four values this list used to hold — `running`, `inProgress`, `started`,
    /// `interacted` — only `running` was ever real, and `pendingInit` (an agent that has
    /// been spawned but has not started yet) was missing, so a just-spawned agent read as
    /// already finished.
    ///
    /// Still an enumeration of the LIVE states rather than the dead ones, and that polarity
    /// is the load-bearing part: a status codex adds in some future release reads as
    /// finished, which under-reports a count for one release, rather than pinning a spinner
    /// on forever with no way for the user to clear it.
    /// Internal rather than private so `CodexSchemaConformanceTests` can assert the real
    /// value against codex's generated schema instead of a copy of it. A copy is how the
    /// wrong four values survived review in the first place.
    static let liveStates: Set<String> = ["pendingInit", "running"]

    static func events(
        method: String, params: [String: Any], state: inout CodexThreadState
    ) -> [AgentEvent] {
        switch method {
        case "thread/name/updated":
            guard let name = params["threadName"] as? String else { return [] }
            return [.title(name)]

        case "turn/started":
            return [.activity(.busy)]

        // `turn/completed` only. There is no `turn/aborted` notification — it appears
        // nowhere in `ServerNotification` in the schema codex generates, at either protocol
        // version, so the case that used to sit here could never fire. An interrupted turn
        // still ends with `turn/completed`, and `thread/status/changed` backs it up.
        case "turn/completed":
            return [.activity(.idle), .turnEnded]

        case "thread/status/changed":
            // Whole status object, not just its `type`: `active` carries `activeFlags`, and
            // those are what tell `.waiting` from `.busy`. See `CodexThreadStatus`.
            guard let activity = CodexThreadStatus.activity(from: params["status"] as? [String: Any])
            else { return [] }
            return [.activity(activity)]

        case "item/started", "item/completed":
            // `agentsStates` is a map of thread id to `CollabAgentState`, which is an OBJECT
            // — `{status: CollabAgentStatus, message?: String}` — not a bare status string.
            // Decoding it as `[String: String]` failed against every real payload, so this
            // guard returned early and `.subagentCount` was never emitted at all. Established
            // from `CollabAgentState` in codex's generated schema at codex-cli 0.147.0.
            guard let item = params["item"] as? [String: Any],
                  item["type"] as? String == "collabAgentToolCall",
                  let states = item["agentsStates"] as? [String: [String: Any]]
            else { return [] }
            // Flattened to id -> status. `message` is deliberately dropped: nothing renders
            // it today, and carrying it would put a free-text field into `Equatable` state
            // that changes on every progress update.
            let statuses = states.compactMapValues { $0["status"] as? String }
            // The live count below is derived straight from this payload's own `statuses`, so
            // nothing here reads `state.subagents` back. It is still recorded — forward-looking
            // state for the runtime Task 9 wires up, which will want per-agent detail (which
            // thread id is in which state) beyond the single number this mapper emits today.
            state.subagents = statuses
            let live = statuses.values.filter { liveStates.contains($0) }.count
            return [.subagentCount(live)]

        default:
            return []
        }
    }

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
