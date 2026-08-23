import FleetKit
import Foundation

/// Turns one line of a codex rollout `.jsonl` into timeline rows.
///
/// Pure and static, exactly like `CodexEventMapper` beside it and `ClaudeTimelineMapper` in
/// the sibling directory.
///
/// **The source is the rollout, not the app-server.** Spec §6 names `item/started` /
/// `item/completed`; those are app-server notifications, and that path was deleted in
/// b76a07b — the notifications only ever reach the connection that made the change, and
/// Flight Deck runs turns in a separate `codex resume` process. `CodexRolloutWatcher` reads
/// this same file for turn boundaries; this reads it for content.
///
/// **The rule that is easy to get wrong is which record FAMILY a row comes from.** Codex
/// writes the same conversation twice, in two shapes:
///
/// - `event_msg` records are the *conversation* — one `user_message` per prompt, one
///   `agent_message` per reply, `agent_reasoning` for renderable thinking.
/// - `response_item` records are the *model transcript* — every tool call and output, plus a
///   second copy of the prose, plus a `role:"user"`/`role:"developer"` message that is not a
///   user turn at all but the assembled prompt (skills, plugin catalogue, environment
///   context: tens of KB, every turn), plus a `reasoning` record that repeats
///   `agent_reasoning`'s text with a multi-kilobyte `encrypted_content` blob attached.
///
/// So: **prose from `event_msg`, tools from `response_item`, nothing from either family's
/// duplicate of the other's job.** Mapping both families for prose doubles every reply;
/// mapping `response_item` / `message` as a user turn pastes an instruction blob into the
/// conversation; mapping `response_item` / `reasoning` doubles every thought and puts
/// ciphertext on the wire.
enum CodexTimelineMapper {
    /// `offset` is the byte offset of this line in the rollout, and it is what makes an item
    /// addressable — see `TimelineItem.id`. One rollout line carries at most one row, so the
    /// block index is always 0; claude's transcript is the format that puts several in a line.
    static func items(inRolloutLine line: String, at offset: Int) -> [TimelineItem] {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let record = raw as? [String: Any],
              let payload = record["payload"] as? [String: Any],
              let kind = payload["type"] as? String
        else { return [] }

        let at = record["timestamp"] as? String
        let id = TimelineItem.identifier(offset: offset, index: 0)

        switch (record["type"] as? String, kind) {
        case ("event_msg", "user_message"):
            guard let text = payload["message"] as? String, !text.isEmpty else { return [] }
            return [item(id, .userTurn, TimelineItem.Body(text: text), at)]

        case ("event_msg", "agent_message"):
            guard let text = payload["message"] as? String, !text.isEmpty else { return [] }
            return [item(id, .assistantText, TimelineItem.Body(text: text), at)]

        case ("event_msg", "agent_reasoning"):
            // The only reasoning worth a row. `response_item`/`reasoning` repeats this exact
            // text under `summary` — 1268 of each in a survey of 494 rollouts on the build
            // machine — with a one-to-two-kilobyte `encrypted_content` blob attached, so
            // taking that family instead would double every thought AND ship the ciphertext.
            guard let text = payload["text"] as? String, !text.isEmpty else { return [] }
            return [item(id, .thinking, TimelineItem.Body(text: text), at)]

        case ("response_item", "function_call"):
            // `arguments` is a JSON **string**, not an object — the one shape difference from
            // claude's `input`. Parsed so the detail screen shows structure rather than one
            // escaped line, and kept verbatim when it is not JSON.
            let decoded = decodedArguments(payload["arguments"])
            return [
                item(id, .toolCall, TimelineItem.Body(
                    text: decoded.text,
                    summary: decoded.summary,
                    tool: payload["name"] as? String,
                    callID: payload["call_id"] as? String
                ), at)
            ]

        case ("response_item", "custom_tool_call"):
            // `input` here is never JSON: `apply_patch` puts a patch in it, and codex-cli
            // 0.148.0's unified `exec` tool puts a JavaScript program in it. Verbatim, with
            // the first line as the row preview.
            let input = payload["input"] as? String ?? ""
            return [
                item(id, .toolCall, TimelineItem.Body(
                    text: input,
                    summary: firstLine(input),
                    tool: payload["name"] as? String,
                    callID: payload["call_id"] as? String
                ), at)
            ]

        case ("response_item", "function_call_output"),
             ("response_item", "custom_tool_call_output"):
            return [
                item(id, .toolResult, TimelineItem.Body(
                    text: outputText(payload["output"]),
                    callID: payload["call_id"] as? String
                ), at)
            ]

        default:
            // Everything else is bookkeeping (`token_count`, `turn_context`, `world_state`,
            // `session_meta`, `thread_settings_applied`), a turn boundary `CodexEventMapper`
            // already owns (`task_started`, `task_complete`, `turn_aborted`), or the other
            // family's duplicate of a row already emitted above — `mcp_tool_call_end`,
            // `patch_apply_end` and `web_search_end` all carry a tool result that the
            // matching `*_output` record has already supplied.
            return []
        }
    }

    private static func item(
        _ id: String, _ kind: TimelineItem.Kind, _ body: TimelineItem.Body, _ at: String?
    ) -> TimelineItem {
        TimelineItem(id: id, kind: kind, status: .complete, body: body, at: at)
    }

    private static func decodedArguments(_ raw: Any?) -> (text: String, summary: String?) {
        guard let text = raw as? String else { return ("", nil) }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
            as? [String: Any]
        else { return (text, firstLine(text)) }
        return (ToolInputSummary.pretty(object), ToolInputSummary.text(for: object))
    }

    /// A tool result's `output` is a String on codex-cli 0.46.0 and a block array on 0.148.0,
    /// and both are in the fixtures. Handling only the String silently renders every tool
    /// result in a current rollout as an empty row.
    ///
    /// Joined with no separator, unlike `ClaudeTimelineMapper.resultText`: codex's blocks are
    /// fragments of one output stream — a `"…Output:\n"` header and then the bytes — and each
    /// already ends with whatever newline belongs to it, so a separator inserts a blank line
    /// that the terminal never showed. Claude's are discrete blocks and do need one.
    private static func outputText(_ output: Any?) -> String {
        if let text = output as? String { return text }
        guard let blocks = output as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
