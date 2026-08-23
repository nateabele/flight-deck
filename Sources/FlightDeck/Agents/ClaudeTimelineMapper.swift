import FleetKit
import Foundation

/// Turns one line of a claude transcript into timeline rows.
///
/// Pure and static so every mapping is testable from a captured line with no process, no
/// socket and no timing — the same reason `ClaudeSession.events(inLine:sessionID:)` and
/// `CodexEventMapper.events(inRolloutLine:)` are.
///
/// **Why this is a second parser and not an extension of `TranscriptWatcher`.** Spec §6 asks
/// claude's mapping to extend the existing watcher path rather than add a second reader.
/// `TranscriptWatcher` is a forward-only tail — one `offset`, never seeking backwards — and
/// backwards pagination over an arbitrary byte range is not something a tail can do. What §6
/// is protecting against is two parses of the same file disagreeing, and that is prevented
/// structurally instead: this is the only place a transcript line is read as *content*, there
/// is still exactly one poll loop per tab, and nothing here touches the watcher's title or
/// sub-agent state. See the plan's findings §4.
///
/// **Two rules here are about what must NOT go on the wire**, and both are silent when
/// broken: a pasted screenshot's base64 (roughly a megabyte per block) and a thinking block's
/// `signature` (a few hundred opaque bytes per block, hundreds of blocks per conversation).
enum ClaudeTimelineMapper {
    /// `offset` is the byte offset of this line in the transcript, and it is what makes an
    /// item addressable — see `TimelineItem.id`.
    static func items(inLine line: String, at offset: Int) -> [TimelineItem] {
        guard let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = record["type"] as? String
        else { return [] }

        // Claude talking to itself: "Continue from where you left off.", the image-geometry
        // note that accompanies a paste. Rendering these as user turns puts words in the
        // user's mouth.
        guard record["isMeta"] as? Bool != true else { return [] }
        // A `/compact` writes its summary of the conversation so far as a `user` record
        // marked `isCompactSummary`. It is several paragraphs of claude's own prose under the
        // user's name — the same harm as `isMeta` on a record long enough to be believed.
        // `ConversationTitle.resolve` already skips both keys together, and the resumed-
        // conversation spec (§9) specifies them as one rule.
        guard record["isCompactSummary"] as? Bool != true else { return [] }
        // Sub-agent records belong in `<conversationId>/subagents/agent-*.jsonl`, which
        // nothing reads. One in the main transcript means claude moved them, and mapping it
        // would interleave a sub-agent's conversation into its parent's.
        guard record["isSidechain"] as? Bool != true else { return [] }

        let at = record["timestamp"] as? String
        guard let message = record["message"] as? [String: Any] else { return [] }

        switch type {
        case "user":
            if let text = message["content"] as? String {
                return [
                    TimelineItem(
                        id: TimelineItem.identifier(offset: offset, index: 0),
                        kind: .userTurn, status: .complete,
                        body: TimelineItem.Body(text: text), at: at
                    )
                ]
            }
            return blocks(message).enumerated().compactMap { index, block in
                userItem(block, offset: offset, index: index, at: at)
            }
        case "assistant":
            return blocks(message).enumerated().compactMap { index, block in
                assistantItem(block, offset: offset, index: index, at: at)
            }
        default:
            return []
        }
    }

    private static func blocks(_ message: [String: Any]) -> [[String: Any]] {
        message["content"] as? [[String: Any]] ?? []
    }

    private static func userItem(
        _ block: [String: Any], offset: Int, index: Int, at: String?
    ) -> TimelineItem? {
        let id = TimelineItem.identifier(offset: offset, index: index)
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String, !text.isEmpty else { return nil }
            return TimelineItem(id: id, kind: .userTurn, status: .complete,
                                body: TimelineItem.Body(text: text), at: at)
        case "image":
            // A placeholder, never the payload. One pasted screenshot is about a megabyte of
            // base64; two in a page is a multi-megabyte frame over a possibly-cellular link,
            // to carry a picture the phone does not draw.
            return TimelineItem(id: id, kind: .userTurn, status: .complete,
                                body: TimelineItem.Body(text: "[image]"), at: at)
        case "tool_result":
            return TimelineItem(
                id: id, kind: .toolResult, status: .complete,
                body: TimelineItem.Body(
                    text: resultText(block["content"]),
                    callID: block["tool_use_id"] as? String,
                    isError: block["is_error"] as? Bool == true
                ),
                at: at
            )
        default:
            // Anything else, and one shape worth naming: a `document` block, which is what a
            // Read of a PDF attaches — the whole file as base64 under `source.data`, exactly
            // like an image. In the captured transcript claude also marks that record
            // `isMeta`, so the guard above catches it first and this arm is the second line of
            // defence. There is no row for a document in this vocabulary yet, so it is dropped
            // rather than approximated.
            return nil
        }
    }

    private static func assistantItem(
        _ block: [String: Any], offset: Int, index: Int, at: String?
    ) -> TimelineItem? {
        let id = TimelineItem.identifier(offset: offset, index: index)
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String, !text.isEmpty else { return nil }
            return TimelineItem(id: id, kind: .assistantText, status: .complete,
                                body: TimelineItem.Body(text: text), at: at)
        case "thinking":
            // `signature` is deliberately not read. An empty `thinking` with a signature is
            // what a redacted block looks like, and there are hundreds of them in a long
            // conversation — emitting each as a blank row is the failure this guard prevents.
            guard let text = block["thinking"] as? String, !text.isEmpty else { return nil }
            return TimelineItem(id: id, kind: .thinking, status: .complete,
                                body: TimelineItem.Body(text: text), at: at)
        case "tool_use":
            let input = block["input"] as? [String: Any]
            return TimelineItem(
                id: id, kind: .toolCall, status: .complete,
                body: TimelineItem.Body(
                    text: ToolInputSummary.pretty(input),
                    summary: input.flatMap(ToolInputSummary.text(for:)),
                    tool: block["name"] as? String,
                    callID: block["id"] as? String
                ),
                at: at
            )
        default:
            return nil
        }
    }

    /// A tool result's `content` is a String for most tools and a block array for some. Both
    /// shapes are real; handling only the first silently drops the second's whole output.
    ///
    /// Only `text` is read out of the array, which is also what keeps an image-returning tool
    /// (a screenshot, `Read` on a `.png`) from putting its base64 on the wire. The cost is
    /// that such a result renders as an empty row rather than as `[image]`; see the task
    /// report.
    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

/// Shared by both mappers, because a tool call looks the same on a phone whichever agent made
/// it: a name, a one-line preview, and the whole input a tap away.
enum ToolInputSummary {
    /// The keys a preview is drawn from, most specific first. A table rather than "the first
    /// String value", which would pick whichever key the JSON happened to order first and
    /// give a `Bash` row its `description` on one call and its `command` on the next.
    private static let previewKeys = [
        "command", "file_path", "path", "pattern", "query", "url", "prompt", "description",
    ]

    /// What a row can show. A list row is one line high and about sixty characters wide, so
    /// this is generous rather than tight.
    ///
    /// **It is also the only bound `summary` gets anywhere.** `TimelineReader` caps an item by
    /// rewriting `body.text` and budgets a page by summing `body.text`; neither reads
    /// `summary`. An unbounded preview would therefore escape both `TimelineLimits.maxItemBytes`
    /// and `maxPageBytes`, up to 200 items to a page — and `prompt` is in the table above, where
    /// an `Agent` dispatch's first paragraph runs to kilobytes with no newline in it, so the
    /// first-line rule alone bounds nothing.
    static let maxSummaryBytes = 200

    /// A one-line row preview, or nil when nothing in the input makes one. Nil is fine: the
    /// row still has `Body.tool` to render.
    static func text(for input: [String: Any]) -> String? {
        for key in previewKeys {
            guard let value = input[key] as? String else { continue }
            let line = value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return capped(trimmed) }
        }
        return nil
    }

    /// Cut on a `Character` boundary so a multi-byte scalar is never halved. No ellipsis is
    /// added: the cap is a transport bound, and how a row elides is the client's business.
    private static func capped(_ line: String) -> String {
        guard line.utf8.count > maxSummaryBytes else { return line }
        var kept = ""
        var bytes = 0
        for character in line {
            let width = String(character).utf8.count
            if bytes + width > maxSummaryBytes { break }
            kept.append(character)
            bytes += width
        }
        return kept
    }

    /// The whole input, for the detail screen. `sortedKeys` so the same call renders the same
    /// way every time it is fetched — an unstable key order would make a re-fetched page look
    /// like a changed one to anything comparing bodies.
    static func pretty(_ input: Any?) -> String {
        guard let input,
              JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(
                  withJSONObject: input, options: [.prettyPrinted, .sortedKeys]
              )
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
