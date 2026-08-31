import Foundation

/// The markers `snippet()` wraps matched terms in.
///
/// U+0002 and U+0003 (START OF TEXT / END OF TEXT) rather than something like `<b>`: the
/// text being marked up is arbitrary conversation content, and any printable delimiter is
/// something a message could legitimately contain — an agent discussing HTML would produce
/// snippets that highlight the wrong span. `TranscriptExtractor` cannot emit these because
/// they are control characters, which is what makes them unambiguous.
public enum SnippetSentinel {
    public static let open: Character = "\u{2}"
    public static let close: Character = "\u{3}"
}

/// Turns FTS5's sentinel-marked snippet into an `AttributedString`.
///
/// Shared between the desktop's overlay and the phone's result rows — both draw the same
/// marked-up snippet the Mac's index produces, and a second parser on either side is how the
/// two screens come to disagree about what got matched.
///
/// An unbalanced opening sentinel — which a snippet truncated at FTS5's window boundary can
/// genuinely produce — emphasises nothing and keeps the remaining text, because losing the
/// rest of the line is far worse than losing a highlight.
public enum SearchSnippet {
    public static func attributed(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(raw)

        while let open = rest.firstIndex(of: SnippetSentinel.open) {
            result += AttributedString(String(rest[rest.startIndex..<open]))
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: SnippetSentinel.close) else {
                result += AttributedString(String(rest[afterOpen...]))
                return result
            }
            var marked = AttributedString(String(rest[afterOpen..<close]))
            marked.inlinePresentationIntent = .stronglyEmphasized
            result += marked
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }
}
