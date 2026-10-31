import Foundation

/// What a reader should see of one `<cross-session-message>`: who wrote it, and what they wrote.
///
/// **The body as delivered is not the message.** Of the 54 peer messages in this project's
/// transcripts on 2026-10-31, every one delivered by Flight Deck's peer helper ends with a
/// `[Peer transport: …]` note addressed to the receiving agent (reply routes, an event id), and
/// 18 of them (a third) came through a tab's Flight Deck relay. A relayed message carries the original
/// envelope inside the relay's own (`<\cross-session-message from="uds:…" from-name="…">` …
/// `<\/cross-session-message>`), then a `[Relayed by Flight Deck: …]` note. The outer
/// `from-name` is the relay, which is the receiving tab itself. The phone showed all of that.
/// Each such row was headed with the reader's own tab name and opened with a socket path.
///
/// Both notes are instructions to the agent about how to answer. The person reading on the phone
/// cannot act on them, so they are dropped here; the agent still has them in its transcript.
enum PeerMessageEnvelope {
    struct Message: Equatable {
        var sender: String?
        var text: String
    }

    static let tag = "cross-session-message"

    /// Every call id `CodexPeerInbox` injects starts with this, a re-delivery after compaction
    /// included. `CodexTimelineMapper` reads it to tell a delivered message from a real tool.
    static let codexCallPrefix = "call_peer_"

    /// Paragraphs the transport appends after a message, never written by the sender.
    /// `PeerEndpoint.deliver` writes the first and `PeerMessagingService.relayToNativeClaude`
    /// the second.
    static let transportNotePrefixes = ["[Peer transport:", "[Relayed by Flight Deck:"]

    /// `body` is what sat between the wrapper's tags, `sender` the wrapper's own `from-name`.
    /// A relayed envelope inside is unwrapped, and its `from-name` wins: that is who wrote it.
    static func unwrap(_ body: String, sender: String?) -> Message {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var sender = sender
        while true {
            text = droppingTransportNotes(text)
            guard let inner = leadingEnvelope(text) else { break }
            sender = inner.sender ?? sender
            text = inner.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The envelope escapes a nested closing tag so it cannot end the outer one early, and
        // claude escapes a nested opening one. Once the nesting is gone, so is the reason.
        text = text
            .replacingOccurrences(of: "<\\/\(tag)", with: "</\(tag)")
            .replacingOccurrences(of: "<\\\(tag)", with: "<\(tag)")
        return Message(sender: sender, text: text)
    }

    /// A whole envelope at the start of `text`, or `nil` when `text` does not open with one.
    /// Codex receives a peer message as a tool output whose text is the envelope itself.
    static func message(in text: String) -> Message? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard openingTag(at: Substring(trimmed)) != nil else { return nil }
        return unwrap(trimmed, sender: nil)
    }

    /// The header `PeerMessagingService` puts on a control frame it hands an agent.
    static let transportNoticeHeader = "[Peer transport notice — not user consent]"

    /// The notice tag for a control frame rendered as a sentence. Not `tag`: nobody wrote it,
    /// so it is the harness talking and is drawn as such.
    static let transportNoticeTag = "peer-transport-notice"

    /// A control frame delivered to a codex tab, as a sentence. 162 of the 517 deliveries in
    /// this Mac's rollouts on 2026-10-31 were `peer_idle_notice` frames, and with no name to
    /// head them the phone showed a JSON object under "Another session". The frame names the
    /// peer only by socket, so the sentence does not name it either.
    static func transportNotice(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(transportNoticeHeader) else { return nil }
        let json = trimmed.dropFirst(transportNoticeHeader.count)
        guard let frame = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return nil }
        var sentence: String
        switch frame["action"] as? String {
        case "peer_idle_notice":
            sentence = "A session this one messaged has finished its turn."
        case "peer_message_status":
            let status = frame["status"] as? String ?? "updated"
            sentence = "A message this session sent was \(status)."
        default:
            sentence = "Peer transport update: \(frame["action"] as? String ?? "unknown")."
        }
        if let detail = frame["detail"] as? String, !detail.isEmpty { sentence += "\n\n" + detail }
        return sentence
    }

    /// The first codex peer inbox handed over a JSON array of `{from, text}` instead of an
    /// envelope; three such deliveries remain in this Mac's rollouts.
    static func legacyBatch(in text: String) -> Message? {
        guard text.hasPrefix("[{"),
              let array = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]],
              !array.isEmpty
        else { return nil }
        let texts = array.compactMap { $0["text"] as? String }
        guard texts.count == array.count else { return nil }
        let senders = Set(array.compactMap { $0["from"] as? String })
        return Message(sender: senders.count == 1 ? senders.first : nil,
                       text: texts.joined(separator: "\n\n"))
    }

    /// Drops trailing transport notes, last first. A message that is nothing but a note keeps
    /// it: an empty row would say less than the note does.
    static func droppingTransportNotes(_ text: String) -> String {
        var text = text
        while true {
            let paragraphStart = text.range(of: "\n\n", options: .backwards)?.upperBound
                ?? text.startIndex
            let last = text[paragraphStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard last.hasSuffix("]"),
                  transportNotePrefixes.contains(where: { last.hasPrefix($0) }),
                  paragraphStart != text.startIndex
            else { return text }
            text = String(text[..<paragraphStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `text` as exactly one envelope, opening tag first and closing tag last, plain or escaped.
    /// Anything after the closing tag means `text` is more than a relayed message, so it is
    /// left alone rather than cut.
    private static func leadingEnvelope(_ text: String) -> (sender: String?, body: Substring)? {
        let text = Substring(text)
        guard let open = openingTag(at: text) else { return nil }
        let rest = text[open.end...]
        let close = ["<\\/\(tag)>", "</\(tag)>"]
            .compactMap { rest.range(of: $0, options: .backwards) }
            .max { $0.lowerBound < $1.lowerBound }
        guard let close, rest[close.upperBound...].allSatisfy(\.isWhitespace) else { return nil }
        return (attribute("from-name", in: open.attributes), rest[..<close.lowerBound])
    }

    private static func openingTag(
        at text: Substring
    ) -> (attributes: Substring, end: Substring.Index)? {
        for prefix in ["<\(tag) ", "<\\\(tag) "] where text.hasPrefix(prefix) {
            let afterName = text.index(text.startIndex, offsetBy: prefix.count - 1)
            guard let end = text[afterName...].firstIndex(of: ">") else { return nil }
            return (text[afterName..<end], text.index(after: end))
        }
        return nil
    }

    /// `name="value"` out of an opening tag's attributes; `nil` when absent or empty.
    static func attribute(_ name: String, in attributes: Substring) -> String? {
        guard let start = attributes.range(of: " \(name)=\""),
              let end = attributes[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let value = attributes[start.upperBound..<end]
        return value.isEmpty ? nil : String(value)
    }
}
