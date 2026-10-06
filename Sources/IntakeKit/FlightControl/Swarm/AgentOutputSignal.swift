import Foundation

/// One pre-commit guard refusal, as the guard prints it:
/// `mcp-agent-mail: file reservation conflict detected! <file> conflicts with reservation '<pattern>' held by <holder>`.
/// The real guard (captured in guard-block.txt) puts a newline and indent between `detected!` and
/// the file, so the scan allows any whitespace there and stores `message` collapsed to one line.
public struct GuardBlock: Codable, Equatable, Sendable {
    public var file: String
    public var pattern: String
    public var holder: String
    public var message: String
    public init(file: String, pattern: String, holder: String, message: String) {
        self.file = file; self.pattern = pattern; self.holder = holder; self.message = message
    }
}

public enum AgentOutputSignal: Equatable, Sendable {
    case guardBlock(GuardBlock)
    /// The text after `BLOCKED:` in a line the agent wrote (the task prompt asks for exactly that).
    case blocked(String)
}

/// Scans one transcript/rollout record for the two things contested detection needs. A cheap
/// substring check on the raw line gates the parse, so ordinary records cost one `contains`.
public enum AgentOutputScan {
    public static let guardMarker = "file reservation conflict detected"
    private static let blockedMarker = "BLOCKED:"

    public static func signals(line: String, record: [String: Any]) -> [AgentOutputSignal] {
        var out: [AgentOutputSignal] = []
        if line.contains(guardMarker) {
            for text in strings(in: record) {
                for block in guardBlocks(in: text) where !out.contains(.guardBlock(block)) { out.append(.guardBlock(block)) }
            }
        }
        if line.contains(blockedMarker) {
            for text in assistantTexts(in: record) {
                for blocked in blockedLines(in: text) where !out.contains(.blocked(blocked)) { out.append(.blocked(blocked)) }
            }
        }
        return out
    }

    public static func guardBlocks(in text: String) -> [GuardBlock] {
        let pattern = #"mcp-agent-mail: file reservation conflict detected!\s+(.+?) conflicts with reservation '([^']+)' held by ([A-Za-z0-9_.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let whole = Range(match.range, in: text), let file = Range(match.range(at: 1), in: text),
                  let pat = Range(match.range(at: 2), in: text), let holder = Range(match.range(at: 3), in: text) else { return nil }
            return GuardBlock(file: String(text[file]), pattern: String(text[pat]), holder: String(text[holder]),
                              message: String(text[whole]).split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
    }

    public static func blockedLines(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(blockedMarker) else { return nil }
            let rest = trimmed.dropFirst(blockedMarker.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
    }

    /// Every string leaf, so the guard message is found in whatever field a harness puts tool
    /// output in.
    static func strings(in value: Any) -> [String] {
        switch value {
        case let s as String: return [s]
        case let d as [String: Any]: return d.values.flatMap(strings(in:))
        case let a as [Any]: return a.flatMap(strings(in:))
        default: return []
        }
    }

    /// Text the agent itself wrote: claude `assistant` records; codex assistant `message` items
    /// and `agent_message` events. Never a user record — the task prompt contains "BLOCKED:".
    static func assistantTexts(in record: [String: Any]) -> [String] {
        if record["type"] as? String == "assistant",
           let message = record["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            return content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        }
        if let payload = record["payload"] as? [String: Any] {
            if payload["type"] as? String == "message", payload["role"] as? String == "assistant",
               let content = payload["content"] as? [[String: Any]] {
                return content.compactMap { $0["text"] as? String }
            }
            if payload["type"] as? String == "agent_message", let message = payload["message"] as? String { return [message] }
        }
        return []
    }
}
