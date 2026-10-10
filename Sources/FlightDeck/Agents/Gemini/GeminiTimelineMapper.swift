import FleetKit
import Foundation

/// Turns one line of agy's `transcript_full.jsonl` into timeline rows.
///
/// One step per line (agy-tui-facts §2): `USER_INPUT` (the user), `PLANNER_RESPONSE` (the model:
/// `thinking`, `content`, `tool_calls`), `GENERIC` (a tool's result; `status:"ERROR"` with an
/// `error` for a denied or failed tool) and `SYSTEM_MESSAGE` (agy talking, under no one's name).
///
/// **A result is NOT paired with its call by id, and cannot be.** The JSONL carries no tool-call
/// id; a result is linked to its call only by order, and a response with several calls is
/// followed by several results (steps `2:132 3:132 4:132` after `1:15` in a real store). A
/// stateless per-line mapper cannot recover that order, so a call's `callID` is synthesized from
/// its own step (`<step>.<n>`) for addressability and a result carries none — it renders as a
/// standalone result rather than as a guess about which command produced it.
enum GeminiTimelineMapper {
    static func items(inLine line: String, at offset: Int) -> [TimelineItem] {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = record["type"] as? String
        else { return [] }
        let at = record["created_at"] as? String
        let step = record["step_index"] as? Int ?? 0
        var index = 0
        func item(_ kind: TimelineItem.Kind, _ body: TimelineItem.Body) -> TimelineItem {
            defer { index += 1 }
            return TimelineItem(id: TimelineItem.identifier(offset: offset, index: index),
                                kind: kind, status: .complete, body: body, at: at)
        }

        switch type {
        case "USER_INPUT":
            guard let text = userText(record["content"] as? String) else { return [] }
            return [item(.userTurn, TimelineItem.Body(text: text))]

        case "PLANNER_RESPONSE":
            var items: [TimelineItem] = []
            if let thinking = nonEmpty(record["thinking"] as? String) {
                items.append(item(.thinking, TimelineItem.Body(text: thinking)))
            }
            if let content = nonEmpty(record["content"] as? String) {
                items.append(item(.assistantText, TimelineItem.Body(text: content)))
            }
            for (n, call) in ((record["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
                let args = call["args"] as? [String: Any] ?? [:]
                items.append(item(.toolCall, TimelineItem.Body(
                    text: ToolInputSummary.pretty(args),
                    summary: nonEmpty(args["toolSummary"] as? String) ?? ToolInputSummary.text(for: args),
                    tool: call["name"] as? String,
                    callID: "\(step).\(n)"
                )))
            }
            return items

        case "GENERIC":
            let isError = (record["status"] as? String) == "ERROR"
            let text = [record["error"] as? String, record["content"] as? String]
                .compactMap { nonEmpty($0) }.joined(separator: "\n\n")
            guard !text.isEmpty else { return [] }
            return [item(.toolResult, TimelineItem.Body(text: text, isError: isError))]

        case "SYSTEM_MESSAGE":
            guard let text = nonEmpty(record["content"] as? String) else { return [] }
            return [item(.systemNotice, TimelineItem.Body(text: text, tool: "agy"))]

        default:
            return []
        }
    }

    /// The user's own words. agy wraps them — `<USER_REQUEST>…</USER_REQUEST>` followed by
    /// `<ADDITIONAL_METADATA>` (the local time) and sometimes `<USER_SETTINGS_CHANGE>` — and
    /// only the request is something the user said. A record with no wrapper is taken whole.
    static func userText(_ content: String?) -> String? {
        guard let content else { return nil }
        if let open = content.range(of: "<USER_REQUEST>"),
           let close = content.range(of: "</USER_REQUEST>", range: open.upperBound..<content.endIndex) {
            return nonEmpty(String(content[open.upperBound..<close.lowerBound]))
        }
        return nonEmpty(content)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
