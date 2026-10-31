import IntakeKit
import SwiftUI

/// A source an agent's reply points at, written `[cite:<id>]` (spec §5). The id grammar is
/// ThreadRunner's provenance ids; what the Mac can open is only what it recognises, and an id it
/// does not recognise stays plain text — a link that opens nothing would promise a source the
/// reply may not have.
enum ThreadCitation: Equatable {
    case intake
    case checkpoint(Int)
    case issue(String)
    case file(path: String, line: Int)

    enum Part: Equatable {
        case text(String)
        case cite(ThreadCitation)
    }

    /// nil for an id that is none of the kinds above.
    static func parse(_ id: String) -> ThreadCitation? {
        let id = id.trimmingCharacters(in: .whitespaces)
        if id == "intake" { return .intake }
        if id.hasPrefix("ckpt:"), let n = Int(id.dropFirst(5)) { return .checkpoint(n) }
        if id.hasPrefix("issue:"), id.count > 6 { return .issue(String(id.dropFirst(6))) }
        // `path:line`. The path must look like one, so "foo:3" in prose is not a file.
        if let colon = id.lastIndex(of: ":"), let line = Int(id[id.index(after: colon)...]), line > 0 {
            let path = String(id[..<colon])
            if path.contains("/") || path.contains(".") { return .file(path: path, line: line) }
        }
        return nil
    }

    /// The reply cut at its citations. Adjacent text is one part, and an unrecognised citation is
    /// folded into the text around it as its bare id.
    static func split(_ reply: String) -> [Part] {
        var parts: [Part] = []
        func append(text: String) {
            guard !text.isEmpty else { return }
            if case .text(let before)? = parts.last { parts[parts.count - 1] = .text(before + text) } else { parts.append(.text(text)) }
        }
        var rest = Substring(reply)
        while let open = rest.range(of: "[cite:"), let close = rest[open.upperBound...].firstIndex(of: "]") {
            append(text: String(rest[..<open.lowerBound]))
            let id = String(rest[open.upperBound..<close])
            if let citation = parse(id) { parts.append(.cite(citation)) } else { append(text: id) }
            rest = rest[rest.index(after: close)...]
        }
        append(text: String(rest))
        return parts
    }

    /// The reply with each citation as its label: the one-line excerpt on a card.
    static func plain(_ reply: String) -> String {
        split(reply).map { part -> String in
            switch part {
            case .text(let text): text
            case .cite(let citation): citation.label
            }
        }.joined()
    }

    var label: String {
        switch self {
        case .intake: "intake"
        case .checkpoint(let n): "checkpoint \(n)"
        case .issue(let id): "issue \(id)"
        case .file(let path, let line): "\((path as NSString).lastPathComponent):\(line)"
        }
    }
}

/// A reply with its citations as chips. Chips are links in one `Text` rather than inline views,
/// so the reply wraps as prose around them; the link's host is the citation's index.
struct ThreadReplyText: View {
    let reply: String
    let open: (ThreadCitation) -> Void

    static let scheme = "fd-cite"

    /// The reply as an attributed string, and the citations its chips point at, in order.
    static func attributed(_ reply: String) -> (text: AttributedString, citations: [ThreadCitation]) {
        var out = AttributedString()
        var citations: [ThreadCitation] = []
        for part in ThreadCitation.split(reply) {
            switch part {
            case .text(let text):
                let markdown = try? AttributedString(markdown: text, options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace))
                out += markdown ?? AttributedString(text)
            case .cite(let citation):
                // Non-breaking spaces pad the chip's tint; the arrow says it goes somewhere.
                var chip = AttributedString("\u{00A0}\(citation.label) ↗\u{00A0}")
                chip.foregroundColor = .accentColor
                chip.backgroundColor = Color.accentColor.opacity(0.14)
                chip.font = .system(size: 11.5, weight: .medium)
                chip.link = URL(string: "\(scheme)://\(citations.count)")
                citations.append(citation)
                out += chip
            }
        }
        return (out, citations)
    }

    var body: some View {
        let built = Self.attributed(reply)
        Text(built.text)
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.scheme, let host = url.host, let at = Int(host), built.citations.indices.contains(at) else {
                    return .systemAction
                }
                open(built.citations[at])
                return .handled
            })
    }
}
