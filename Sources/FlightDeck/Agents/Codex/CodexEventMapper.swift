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
    /// States that mean a sub-agent is still occupying a slot. Anything else — completed,
    /// failed, cancelled — is finished. Listing the *live* states rather than the dead ones
    /// means an unfamiliar state reads as finished, so an unknown value cannot pin the
    /// spinner on forever.
    private static let liveStates: Set<String> = ["running", "inProgress", "started", "interacted"]

    static func events(
        method: String, params: [String: Any], state: inout CodexThreadState
    ) -> [AgentEvent] {
        switch method {
        case "thread/name/updated":
            guard let name = params["threadName"] as? String else { return [] }
            return [.title(name)]

        case "turn/started":
            return [.activity(.busy)]

        case "turn/completed", "turn/aborted":
            return [.activity(.idle), .turnEnded]

        case "thread/status/changed":
            guard let raw = (params["status"] as? [String: Any])?["type"] as? String,
                  let activity = activity(forThreadStatus: raw)
            else { return [] }
            return [.activity(activity)]

        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any],
                  item["type"] as? String == "collabAgentToolCall",
                  let states = item["agentsStates"] as? [String: String]
            else { return [] }
            state.subagents = states
            let live = states.values.filter { liveStates.contains($0) }.count
            return [.subagentCount(live)]

        default:
            return []
        }
    }

    private static func activity(forThreadStatus raw: String) -> SessionActivity? {
        switch raw {
        case "running", "busy": .busy
        case "idle", "notLoaded": .idle
        default: nil   // an unknown status must not overwrite a known one
        }
    }
}
