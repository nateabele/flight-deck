import FleetKit
import Foundation
import IntakeKit

/// One line of an OpenCode mirror (`OpenCodeMirror`) as timeline items.
///
/// Pure and fixture-tested, like its two siblings. The line shapes are this app's own — the
/// mirror writes them — so unlike claude's and codex's mappers this one is not chasing a
/// format somebody else can change; what it does chase is OpenCode's PART vocabulary, which is
/// carried through verbatim inside each `message` record.
enum OpenCodeTimelineMapper {
    static func items(inLine line: String, at offset: Int) -> [TimelineItem] {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = record["type"] as? String
        else { return [] }
        let at = timestamp(record["time"])
        var builder = Builder(offset: offset, at: at)

        switch type {
        case "message":
            let parts = record["parts"] as? [[String: Any]] ?? []
            if record["role"] as? String == "user" {
                for part in parts where part["type"] as? String == "text" {
                    // Synthetic parts are text OpenCode injects into a user turn itself — file
                    // contents an `@mention` expanded to, a compaction summary. Showing them as
                    // something the user said would put words in their mouth.
                    guard part["synthetic"] as? Bool != true,
                          let text = part["text"] as? String, !text.isEmpty else { continue }
                    builder.add(.userTurn, TimelineItem.Body(text: text))
                }
            } else {
                for part in parts { assistant(part, into: &builder) }
                if let notice = errorNotice(record["error"]) {
                    builder.add(.systemNotice, TimelineItem.Body(text: notice, isError: true))
                }
            }

        case "prompt.asked":
            guard let id = record["id"] as? String else { return [] }
            if record["kind"] as? String == "question" {
                // Re-spelled into the `AskUserQuestion` input shape `PromptQuestion.all` already
                // parses, rather than teaching FleetKit a second question format: OpenCode says
                // `multiple` where claude says `multiSelect`, and nothing else differs.
                let questions = (record["questions"] as? [[String: Any]] ?? []).map { question in
                    var spelled = question
                    spelled["multiSelect"] = question["multiple"] as? Bool ?? false
                    spelled["multiple"] = nil
                    return spelled
                }
                let input = OpenCodeEventMapper.encode(["questions": questions])
                let first = questions.first?["question"] as? String
                builder.add(.prompt, TimelineItem.Body(
                    text: input, summary: first.flatMap(ToolInputSummary.preview(of:)),
                    tool: "question", callID: id
                ))
            } else {
                // A permission request, drawn as the tool call it gates — an unanswered call is
                // exactly what `OpenPrompt.find` reads as "a permission dialog is up".
                let permission = record["permission"] as? String ?? "permission"
                let metadata = record["metadata"] as? [String: Any] ?? [:]
                let patterns = record["patterns"] as? [String] ?? []
                let detail = (metadata["command"] as? String)
                    ?? (metadata["filepath"] as? String)
                    ?? (metadata["filePath"] as? String)
                    ?? patterns.joined(separator: "\n")
                builder.add(.toolCall, TimelineItem.Body(
                    text: detail, summary: ToolInputSummary.preview(of: detail),
                    tool: permission, callID: id
                ))
            }

        case "prompt.resolved":
            guard let id = record["id"] as? String else { return [] }
            let outcome = record["outcome"] as? String ?? "replied"
            let text: String
            var isError = false
            switch outcome {
            case "once": text = "Allowed once"
            case "always": text = "Allowed always"
            case "reject": text = "Rejected"; isError = true
            case "rejected": text = "Dismissed"; isError = true
            // Written by the runtime, not OpenCode: the server no longer has the request — it
            // was answered while Flight Deck was not listening, or a server restart dropped it.
            case "gone": text = "No longer pending"
            case "answered":
                let answers = (record["answers"] as? [[String]] ?? []).map { $0.joined(separator: ", ") }
                text = answers.isEmpty ? "Answered" : "Answered: " + answers.joined(separator: "; ")
            default: text = outcome
            }
            builder.add(.toolResult, TimelineItem.Body(text: text, callID: id, isError: isError))

        default:
            return []
        }
        return builder.items
    }

    private static func assistant(_ part: [String: Any], into builder: inout Builder) {
        switch part["type"] as? String {
        case "text":
            guard let text = part["text"] as? String, !text.isEmpty else { return }
            builder.add(.assistantText, TimelineItem.Body(text: text))
        case "reasoning":
            guard let text = part["text"] as? String, !text.isEmpty else { return }
            builder.add(.thinking, TimelineItem.Body(text: text))
        case "tool":
            let tool = part["tool"] as? String ?? "tool"
            let callID = part["callID"] as? String
            let state = part["state"] as? [String: Any] ?? [:]
            let input = state["input"] as? [String: Any] ?? [:]
            builder.add(.toolCall, TimelineItem.Body(
                text: ToolInputSummary.pretty(input),
                summary: summary(of: input, title: state["title"] as? String),
                tool: tool, callID: callID
            ))
            switch state["status"] as? String {
            case "completed":
                builder.add(.toolResult, TimelineItem.Body(
                    text: state["output"] as? String ?? "", callID: callID,
                    truncatedBytes: state["truncated"] as? Int ?? 0
                ))
            case "error":
                builder.add(.toolResult, TimelineItem.Body(
                    text: state["error"] as? String ?? "Tool failed", callID: callID, isError: true
                ))
            default:
                // A tool still pending or running inside a SETTLED message was cut off — the
                // turn was aborted mid-call. It is closed here rather than left open, because an
                // unanswered call while the tab is `waiting` is what `OpenPrompt.find` reads as a
                // live permission dialog, and this one can never be answered.
                builder.add(.toolResult, TimelineItem.Body(
                    text: "Interrupted", callID: callID, isError: true
                ))
            }
        case "patch":
            let files = part["files"] as? [String] ?? []
            guard !files.isEmpty else { return }
            let names = files.map { ($0 as NSString).lastPathComponent }
            builder.add(.systemNotice, TimelineItem.Body(
                text: "Changed \(files.count == 1 ? "1 file" : "\(files.count) files"): "
                    + names.joined(separator: ", ")
            ))
        case "subtask", "agent":
            let name = (part["agent"] as? String) ?? (part["name"] as? String) ?? "subagent"
            let description = (part["description"] as? String) ?? (part["prompt"] as? String) ?? ""
            builder.add(.systemNotice, TimelineItem.Body(
                text: description.isEmpty ? "Started @\(name)" : "Started @\(name): \(description)"
            ))
        default:
            return
        }
    }

    /// OpenCode's tool inputs are camelCase (`filePath`), claude's snake_case (`file_path`), so
    /// the shared preview keys miss the commonest OpenCode tools. The tool's own `title` — what
    /// OpenCode's TUI prints beside the call — is the better summary whenever there is one.
    private static func summary(of input: [String: Any], title: String?) -> String? {
        if let title, let preview = ToolInputSummary.preview(of: title) { return preview }
        if let text = ToolInputSummary.text(for: input) { return text }
        for key in ["filePath", "filepath"] {
            if let value = input[key] as? String, let preview = ToolInputSummary.preview(of: value) {
                return preview
            }
        }
        return nil
    }

    private static func errorNotice(_ raw: Any?) -> String? {
        guard let error = raw as? [String: Any], let name = error["name"] as? String else { return nil }
        if name == "MessageAbortedError" { return "Interrupted" }
        let message = (error["data"] as? [String: Any])?["message"] as? String
        return message.map { "\(name): \($0)" } ?? name
    }

    private static func timestamp(_ raw: Any?) -> String? {
        guard let millis = (raw as? NSNumber)?.doubleValue else { return nil }
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private struct Builder {
        let offset: Int
        let at: String?
        var items: [TimelineItem] = []

        mutating func add(_ kind: TimelineItem.Kind, _ body: TimelineItem.Body) {
            items.append(TimelineItem(
                id: TimelineItem.identifier(offset: offset, index: items.count),
                kind: kind, status: .complete, body: body, at: at
            ))
        }
    }
}
