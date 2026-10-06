import Foundation

struct PendingDialog: Equatable, Sendable {
    let agentID: String?
    let callID: String
}

/// Which agent and call the dialog on screen belongs to, from the hook log.
///
/// claude draws a background subagent's permission dialog in the parent's TUI, so the
/// screen and the registry cannot say whose it is. `PermissionRequest` fires at raise; if it
/// does not carry `tool_use_id` itself, the `PreToolUse` that preceded it for the same tool
/// and input does (verified: `PreToolUse` carries `agent_id` and `tool_use_id`). Esc fires
/// no hook, so this never decides a dialog is still open: `PromptService` confirms against
/// the transcript.
struct DialogAttribution {
    enum Change: Equatable {
        case raised(UUID, PendingDialog)
        case cleared(UUID)
        case promptSubmitted(UUID, Date)
    }
    private struct Pre { let agentID: String?; let toolUseID: String; let tool: String?; let input: String? }
    private var recent: [UUID: [Pre]] = [:]
    private var pending: [UUID: PendingDialog] = [:]
    var now: () -> Date = Date.init

    mutating func apply(_ r: HookEventRecord) -> Change? {
        switch r.event {
        case "PreToolUse":
            guard let id = r.toolUseID else { return nil }
            var list = recent[r.sessionID] ?? []
            list.append(Pre(agentID: r.agentID, toolUseID: id, tool: r.toolName, input: r.toolInput))
            recent[r.sessionID] = Array(list.suffix(32))
            return nil
        case "PermissionRequest":
            // A subagent's request always carries agent_id, so an id-less one is the main
            // agent's: matching nil == nil keeps a main-agent dialog from being attributed to
            // a subagent's identical recent call.
            let callID = r.toolUseID ?? recent[r.sessionID]?.last(where: {
                $0.tool == r.toolName && $0.input == r.toolInput && $0.agentID == r.agentID
            })?.toolUseID
            guard let callID else { return nil }
            // A request carrying its own tool_use_id but no agent_id: that id is unique, so
            // the PreToolUse with the same id names the agent.
            let agent = r.agentID
                ?? (r.toolUseID != nil ? recent[r.sessionID]?.last { $0.toolUseID == callID }?.agentID : nil)
            let dialog = PendingDialog(agentID: agent, callID: callID)
            pending[r.sessionID] = dialog
            return .raised(r.sessionID, dialog)
        case "PostToolUse":
            guard let id = r.toolUseID, pending[r.sessionID]?.callID == id else { return nil }
            pending[r.sessionID] = nil
            return .cleared(r.sessionID)
        case "UserPromptSubmit":
            pending[r.sessionID] = nil
            return .promptSubmitted(r.sessionID, now())
        case "SessionEnd":
            pending[r.sessionID] = nil
            recent[r.sessionID] = nil
            return .cleared(r.sessionID)
        default:
            return nil
        }
    }
}
