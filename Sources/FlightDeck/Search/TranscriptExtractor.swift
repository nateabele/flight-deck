import Foundation

/// Pulls the conversation out of a transcript line and throws the rest away.
///
/// **Why so little survives.** Sampling 60 transcripts (97 MB): the JSON envelope is 54.5%
/// of the bytes, `tool_result` 19.9%, `tool_use` 8.9%, base64 images 0.9%, and user plus
/// assistant text just 5.0%. Indexing only that 5% turns a 684 MB corpus into ~34 MB, which
/// is what makes the index small enough to stop being the hard part of this feature.
///
/// **Why not the tool blocks.** They are not merely large, they change what searching
/// means: with tool results indexed, `rename` matches every file Claude ever read that
/// contains the word, drowning the one message where somebody asked for a rename. They also
/// wreck the preview, which is a two-line extract that only reads well when it is a
/// sentence a person or an agent actually wrote.
///
/// Pure and synchronous: no file handles, no state. `SearchIndexBuilder` and
/// `TranscriptWatcher` both feed it lines they have already read.
enum TranscriptExtractor {
    /// Shared because `ISO8601DateFormatter` is expensive to construct and this runs once
    /// per record across hundreds of thousands of records during a backfill.
    ///
    /// `.withFractionalSeconds` is required, not optional: claude writes
    /// `2026-08-26T21:57:19.490Z`, and the default option set rejects the milliseconds
    /// outright rather than ignoring them — every timestamp would silently parse as nil and
    /// every transcript hit would fall back to file mtime.
    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func messages(inLine line: String, conversationID: String) -> [IndexedMessage] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return messages(inObject: object, conversationID: conversationID)
    }

    /// The same rule against an already-decoded record.
    ///
    /// `TranscriptWatcher` decodes every line anyway to find titles and subagent counts
    /// (`ClaudeSession.events(inObject:)`); handing back the already-parsed object here is
    /// what keeps that second, expensive `JSONSerialization` pass from happening at all.
    static func messages(inObject object: [String: Any], conversationID: String) -> [IndexedMessage] {
        guard let role = IndexedMessage.Role(rawValue: object["type"] as? String ?? "")
        else { return [] }

        // The harness talking to itself rather than a person talking to an agent. Matches
        // the exclusions `ConversationTitle.resolve` already applies when it picks a name
        // out of the first real user message.
        guard object["isMeta"] as? Bool != true,
              object["isCompactSummary"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return [] }

        let timestamp = (object["timestamp"] as? String).flatMap(timestamps.date(from:))

        return texts(inContent: message["content"]).compactMap { text in
            // Trimmed before the emptiness check so a record whose whole content is a
            // newline does not become an index row that can never match anything but still
            // costs a row, a rowid, and a slot in every `LIMIT 200`.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return IndexedMessage(
                conversationID: conversationID, role: role, text: trimmed, timestamp: timestamp
            )
        }
    }

    /// `content` is either a bare string or an array of typed blocks — the same two shapes
    /// `ConversationTitle.userText` handles. Only `text` blocks are taken; `tool_use`,
    /// `tool_result`, `image` and `thinking` are dropped on purpose (see the type comment).
    private static func texts(inContent content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
    }
}
