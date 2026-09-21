import Foundation

/// Whether an agent's own input box is there to be typed into, derived from the agent's
/// lifecycle rather than from its pixels.
///
/// **Busy versus idle is deliberately absent.** Mid-turn injection is fine — Claude queues
/// it — so every non-terminal event collapses to `.live`. Activity already has an owner,
/// (`ClaudeStatusFile` → `AgentEvent.activity`); a second, differently-derived answer to
/// the same question would be free to disagree with it.
///
/// **A dialog state is deliberately absent too.** Denying a permission prompt with Esc
/// fires no hook at all (probe, 2026-09-19), so a `.dialog` entered by `PermissionRequest`
/// would have no observable clear: it would refuse injection, and the only event that
/// would clear it — `UserPromptSubmit` — is the one being refused. Dialogs are answered by
/// `AgentTextChannel.isKnownNonComposer` instead.
enum ComposerReadiness: Equatable, Sendable {
    /// No events seen for this session. Falls back to the legacy screen grammar, which is
    /// what a session restored from an older build, or one in an untrusted folder, gets.
    case unknown
    case live
    case absent
}

/// One line of the hook event log, reduced to the two fields that matter.
struct HookEventRecord: Equatable {
    let sessionID: UUID
    let event: String

    /// Fails closed: anything unrecognised yields nil and the caller keeps its last state.
    static func decode(_ line: String) -> HookEventRecord? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = obj["session_id"] as? String,
              let sessionID = UUID(uuidString: rawID),
              let event = obj["hook_event_name"] as? String
        else { return nil }
        return HookEventRecord(sessionID: sessionID, event: event)
    }
}

extension ComposerReadiness {
    /// The whole state machine. Unknown names return `current` unchanged, so an upstream
    /// rename degrades to the previous answer rather than to a wrong one.
    static func applying(_ event: String, to current: ComposerReadiness) -> ComposerReadiness {
        switch event {
        case "SessionEnd":
            return .absent
        case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop":
            return .live
        default:
            return current
        }
    }
}
