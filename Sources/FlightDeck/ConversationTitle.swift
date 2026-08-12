import Foundation

/// What to call a Claude conversation we did not start.
///
/// Mirrors what `claude` itself displays in its `/resume` picker, verified against the
/// 2.1.227 binary: a conversation's own name when it has one, otherwise its first real
/// user message (`cba` → `CIn`). See
/// `docs/superpowers/specs/2026-08-11-resumed-conversation-pinning-design.md` §9.
///
/// Deliberately NOT sourced from the `name` field of `~/.claude/sessions/<pid>.json`.
/// `claude` writes that field and the `sessionId` field through separate hops of the same
/// promise chain, so a poll can observe the newly resumed conversation still carrying the
/// previous one's name.
enum ConversationTitle {
    /// Pure so the record shapes are testable without a filesystem.
    ///
    /// Rename records are not filtered by session id, unlike `ClaudeSession.customTitle`:
    /// the file *is* the conversation, so every rename record in it is this conversation's.
    static func resolve(lines: [String]) -> String? {
        var lastName: String?
        var firstUserText: String?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "agent-name":
                if let name = obj["agentName"] as? String { lastName = name }
            case "custom-title":
                if let name = obj["customTitle"] as? String { lastName = name }
            case "user":
                guard firstUserText == nil,
                      obj["isMeta"] as? Bool != true,
                      obj["isCompactSummary"] as? Bool != true,
                      let text = userText(obj)
                else { continue }
                firstUserText = text
            default:
                continue
            }
        }

        guard let raw = lastName ?? firstUserText else { return nil }
        // Shares the app's single sanitizer, so the 120-char cap and the control- and
        // shell-metacharacter stripping applied to every other title apply here too. That
        // keeps the stored title byte-identical to what a rename would inject, which is
        // what `SessionStore.applyExternalTitle`'s loop guard compares against.
        return ClaudeSession.sanitizedName(raw.replacingOccurrences(of: "\n", with: " "))
    }

    /// A missing or unreadable file is nil, not an error: it just means we have nothing
    /// better to call the conversation than whatever the tab is already called.
    static func resolve(transcriptAt url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return resolve(lines: contents.components(separatedBy: "\n"))
    }

    /// `content` is either a bare string or an array of typed blocks; take the first text.
    private static func userText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String { return text }
        }
        return nil
    }
}
