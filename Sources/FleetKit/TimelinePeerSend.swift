import Foundation

/// A message this session sent another one, drawn as the message rather than as the tool call
/// that sent it.
///
/// **Why.** A conversation between two sessions read as half a conversation on the phone. The
/// other side's messages were prose under the sender's name. This side's replies were a
/// `SendMessage` card showing a JSON tree, or a terminal card showing one clipped line of
/// `cd …; flightdeck peer send "The Plan" 'Visual Companion 2 here. My answers…`. This
/// project's claude transcripts on 2026-10-31 held 45 of the first and 33 of the second.
///
/// **Here, on the reader's side, and not in the Mac's mapper**, for two reasons. A phone paired
/// with an older Mac gets the same rows. And the call's result, which says whether the send
/// failed, is joined to the call only by `TimelineRender.entries(from:)`, which is the step
/// before this one.
///
/// **Parsed only where failing is harmless.** A call this cannot read whole is left as the
/// tool card it was: a body cut at the byte cap, a spilled placeholder, a message built by
/// command substitution, a command that does more than send.
public enum TimelinePeerSend {
    /// The notice tag of a rewritten row. Its `sender` is the recipient.
    public static let tool = "sent-cross-session-message"

    /// The notice tag of a message another session sent this one (`PeerMessageEnvelope.tag`).
    public static let receivedTool = "cross-session-message"

    /// Every send in `entries` rewritten, each recipient named.
    ///
    /// **Named from the feed itself.** A reply goes to the address the message came from, and
    /// in this project's transcripts on 2026-10-31 a third of all `SendMessage` calls (40 of
    /// 120) named a `uds:` socket, which the phone drew as "To another session". Every one of
    /// those sockets had sent a message earlier in the same transcript, under a name. The
    /// latest name wins, so a tab renamed mid-conversation is called what it is now. A tab id
    /// is named by `tabTitle`, the fleet's list, because no envelope carries one.
    public static func rewritten(
        _ entries: [TimelineEntry], tabTitle: (UUID) -> String? = { _ in nil }
    ) -> [TimelineEntry] {
        var directory: [String: String] = [:]
        for entry in entries {
            let body = entry.item.body
            guard entry.item.kind == .systemNotice, body.tool == receivedTool,
                  let address = body.senderAddress, let name = body.sender, !name.isEmpty
            else { continue }
            directory[address] = name
        }
        return entries.map { rewritten($0) { address in
            directory[address] ?? UUID(uuidString: address).flatMap(tabTitle)
        } }
    }

    /// One entry, its recipient named by `name` where that knows the address.
    public static func rewritten(
        _ entry: TimelineEntry, name: (String) -> String? = { _ in nil }
    ) -> TimelineEntry {
        let item = entry.item
        guard item.kind == .toolCall, !item.body.isPlaceholder, item.body.truncatedBytes == 0,
              var sent = message(in: item)
        else { return entry }
        let address = sent.recipient
        sent.recipient = name(address) ?? recipientName(address)
        let failed = item.body.isError || entry.result.map(isFailure) == true
        return TimelineEntry(
            item: TimelineItem(
                id: item.id, kind: .systemNotice, status: item.status,
                body: TimelineItem.Body(
                    text: sent.text, tool: tool, callID: item.body.callID,
                    isError: failed, sender: sent.recipient, senderAddress: address
                ),
                at: item.at
            ),
            result: nil
        )
    }

    /// `recipient` is the address as written: a name, a tab id, a socket.
    public struct Sent: Equatable {
        public var recipient: String
        public var text: String
    }

    /// The recipient and the words of one send, or `nil` when `item` is not one.
    ///
    /// Runs on every redraw of the feed, over every tool call in it, so the name and a substring
    /// decide first and only a likely send is decoded.
    public static func message(in item: TimelineItem) -> Sent? {
        switch item.body.tool {
        case "SendMessage":
            guard let input = object(item.body.text), let to = input["to"] as? String,
                  let text = input["message"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return Sent(recipient: to, text: text)
        case "Bash":
            guard item.body.text.contains("flightdeck peer send "),
                  let command = object(item.body.text)?["command"] as? String
            else { return nil }
            return peerSend(in: command)
        default:
            return nil
        }
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// An address nothing in the feed or the fleet names, as a reader would say it. A socket
    /// path names no one, and a sub-agent's id is long enough to wrap the heading.
    static func recipientName(_ to: String) -> String {
        // A tab id names a session as precisely as a socket does, and as unreadably.
        if to.hasPrefix("uds:") || UUID(uuidString: to) != nil { return "another session" }
        let isAgentID = to.count == 17 && to.first == "a"
            && to.dropFirst().allSatisfy { $0.isHexDigit }
        return isAgentID ? "agent \(to.dropFirst().prefix(7))" : to
    }

    /// A `SendMessage` result is `{"success":false,…}` on failure, not an error result.
    private static func isFailure(_ result: TimelineItem) -> Bool {
        if result.body.isError { return true }
        return object(result.body.text)?["success"] as? Bool == false
    }

    /// `flightdeck peer send <to> <message>` in a shell command, as two literal words.
    ///
    /// What may come before it is a `cd`, joined by `;`, `&&` or a newline: that is how both
    /// agents spell "in this checkout". What comes after the message is not read, so
    /// `2>&1 | tail -1` and `--notify-when-idle` do not hide the row. A word with an unquoted or
    /// double-quoted `$` or a backtick is not literal, so it is not a message this can show.
    static func peerSend(in command: String) -> Sent? {
        let marker = "flightdeck peer send "
        guard let start = command.range(of: marker) else { return nil }
        let before = command[..<start.lowerBound]
        guard before.isEmpty || isPreamble(before) else { return nil }
        var words: [String] = []
        var rest = command[start.upperBound...]
        while words.count < 2 {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard let (word, next) = shellWord(rest) else { return nil }
            rest = next
            if word.hasPrefix("--") {
                // `--from TAB` names the sender, not the recipient; its value is skipped with it.
                if word == "--from" {
                    rest = rest.drop { $0 == " " || $0 == "\t" }
                    guard let (_, next) = shellWord(rest) else { return nil }
                    rest = next
                }
                continue
            }
            words.append(word)
        }
        guard !words[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command[start.upperBound...].range(of: marker) == nil
        else { return nil }
        return Sent(recipient: words[0], text: words[1])
    }

    /// Only `cd <one word>` statements, so a command that runs something else first is still
    /// drawn as the command it is.
    private static func isPreamble(_ text: Substring) -> Bool {
        let tail = text.trimmingCharacters(in: .whitespaces)
        guard tail.hasSuffix(";") || tail.hasSuffix("&&") || text.hasSuffix("\n") else { return false }
        let statements = text
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return !statements.isEmpty && statements.allSatisfy { statement in
            guard statement.hasPrefix("cd ") else { return false }
            let rest = Substring(statement.dropFirst(3)).drop { $0 == " " }
            guard let (_, after) = shellWord(rest) else { return false }
            return after.allSatisfy { $0 == " " }
        }
    }

    /// One shell word from the start of `text`: single quotes, double quotes and backslashes,
    /// joined as the shell joins them (`'it'\''s'` is `it's`). `nil` at the end of the
    /// command, at an operator, or at anything the shell would expand.
    private static func shellWord(_ text: Substring) -> (String, Substring)? {
        var word = ""
        var index = text.startIndex
        var any = false
        while index < text.endIndex {
            let c = text[index]
            switch c {
            case " ", "\t", "\n", ";", "&", "|", ">", "<", "(", ")":
                return any ? (word, text[index...]) : nil
            case "$", "`":
                return nil
            case "'":
                guard let close = text[text.index(after: index)...].firstIndex(of: "'")
                else { return nil }
                word += text[text.index(after: index)..<close]
                index = text.index(after: close)
            case "\"":
                var i = text.index(after: index)
                var closed = false
                while i < text.endIndex {
                    let d = text[i]
                    if d == "\"" { closed = true; break }
                    if d == "$" || d == "`" { return nil }
                    if d == "\\", text.index(after: i) < text.endIndex,
                       "\"\\$`\n".contains(text[text.index(after: i)]) {
                        i = text.index(after: i)
                    }
                    word.append(text[i])
                    i = text.index(after: i)
                }
                guard closed else { return nil }
                index = text.index(after: i)
            case "\\":
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                word.append(text[next])
                index = text.index(after: next)
            default:
                word.append(c)
                index = text.index(after: index)
            }
            any = true
        }
        return any ? (word, text[text.endIndex...]) : nil
    }
}
