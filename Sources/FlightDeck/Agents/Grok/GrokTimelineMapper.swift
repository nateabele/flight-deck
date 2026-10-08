import FleetKit
import Foundation

/// Turns one line of a grok session's `updates.jsonl` into timeline rows.
///
/// Pure and static, like `CodexTimelineMapper`. Each line is one ACP `session/update`
/// notification (grok 1.0.30, facts §2):
/// `{"timestamp":<s>,"method":"session/update","params":{"sessionId",
///   "update":{"sessionUpdate":<kind>,…},"_meta":{"eventId","agentTimestampMs",…}}}`.
///
/// **Which kinds become rows.** `user_message_chunk` carries the whole prompt in one record and
/// `agent_message_chunk` one whole assistant message in the TUI (headless runs stream several
/// chunks per message; a tab is never headless). `agent_thought_chunk` is reasoning. A
/// `tool_call` is written AT RAISE, before any permission card, which is what makes an
/// unanswered call the open dialog. A `tool_call_update` is a result only once it carries a
/// terminal `status` — grok writes an earlier update with no status at all (just `locations`),
/// and mapping that would close the call before it ran. `turn_completed`, `hook_execution`,
/// `background_tasks` and the rest are bookkeeping.
///
/// **`ask_user_question` is a `.prompt`, not a `.toolCall`**, for the same reason claude's
/// `AskUserQuestion` is: its body is the question set `OpenPrompt.find` parses. Its input shape
/// was not captured live (the probe answered one by keypress, not by reading the record);
/// grok's string table names the same `questions` member claude uses, and a body that does not
/// parse yields no card at all — `OpenPrompt.find` refuses rather than drawing Allow/Deny.
enum GrokTimelineMapper {
    static let questionTool = "ask_user_question"

    static func items(inLine line: String, at offset: Int) -> [TimelineItem] {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let record = raw as? [String: Any]
        else { return [] }
        return items(inRecord: record, at: offset)
    }

    static func items(inRecord record: [String: Any], at offset: Int) -> [TimelineItem] {
        guard let params = record["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String
        else { return [] }
        let id = TimelineItem.identifier(offset: offset, index: 0)
        let at = timestamp(record)

        switch kind {
        case "user_message_chunk":
            guard let text = contentText(update) else { return [] }
            return [item(id, .userTurn, TimelineItem.Body(text: text), at)]
        case "agent_message_chunk":
            guard let text = contentText(update) else { return [] }
            return [item(id, .assistantText, TimelineItem.Body(text: text), at)]
        case "agent_thought_chunk":
            guard let text = contentText(update) else { return [] }
            return [item(id, .thinking, TimelineItem.Body(text: text), at)]
        case "tool_call":
            guard let callID = update["toolCallId"] as? String else { return [] }
            let name = toolName(update)
            let input = update["rawInput"] as? [String: Any] ?? [:]
            if name == questionTool {
                return [item(id, .prompt, TimelineItem.Body(
                    text: json(input), tool: name, callID: callID), at)]
            }
            return [item(id, .toolCall, TimelineItem.Body(
                text: ToolInputSummary.pretty(input), summary: ToolInputSummary.text(for: input),
                tool: name, callID: callID), at)]
        case "tool_call_update":
            guard let callID = update["toolCallId"] as? String,
                  let status = update["status"] as? String,
                  status == "completed" || status == "failed"
            else { return [] }
            return [item(id, .toolResult, TimelineItem.Body(
                text: resultText(update), callID: callID, isError: status == "failed"), at)]
        default:
            return []
        }
    }

    /// The tool's own name (`_meta["x.ai/tool"].name`, e.g. `write`, `run_terminal_command`),
    /// else the record's `title`, which on a `tool_call` is that same name.
    static func toolName(_ update: [String: Any]) -> String? {
        if let meta = update["_meta"] as? [String: Any],
           let tool = meta["x.ai/tool"] as? [String: Any],
           let name = tool["name"] as? String {
            return name
        }
        return update["title"] as? String
    }

    private static func contentText(_ update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              let text = content["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// A result's text: its content blocks' text, else `rawOutput` as text. A rejection reads
    /// "User rejected the execution for tool `write`" in a text block (probed), which is the
    /// sentence the row should show.
    private static func resultText(_ update: [String: Any]) -> String {
        if let blocks = update["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if let inner = block["content"] as? [String: Any] { return inner["text"] as? String }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        if let output = update["rawOutput"] as? String { return output }
        if let output = update["rawOutput"] { return json(output) }
        return ""
    }

    /// `_meta.agentTimestampMs` as ISO-8601, else the record's whole-second `timestamp`.
    static func timestamp(_ record: [String: Any]) -> String? {
        let params = record["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        let seconds: Double
        if let ms = (meta?["agentTimestampMs"] as? NSNumber)?.doubleValue {
            seconds = ms / 1000
        } else if let s = (record["timestamp"] as? NSNumber)?.doubleValue {
            seconds = s
        } else {
            return nil
        }
        return iso.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return (value as? String) ?? "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func item(
        _ id: String, _ kind: TimelineItem.Kind, _ body: TimelineItem.Body, _ at: String?
    ) -> TimelineItem {
        TimelineItem(id: id, kind: kind, status: .complete, body: body, at: at)
    }
}
