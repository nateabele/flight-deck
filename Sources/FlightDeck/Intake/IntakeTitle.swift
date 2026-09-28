import Foundation

/// A short title cut from an intake's intent, which is whatever the user typed — often a whole
/// paragraph. The detail header shows `title` over the full request (collapsed); the intakes
/// list shows `lead` in bold running into `rest`. Pure, so `IntakeTitleTests` can pin the cuts.
///
/// The cut, in order: the first line, then its first sentence; a sentence longer than `limit`
/// is cut at its first clause break (": ", " — ", "; ") if that leaves a real title, else at its
/// last comma in reach, else at the last word that fits — those two with an ellipsis. Never mid-word: a title that stops at "dispa…" reads
/// as a rendering bug rather than a summary.
struct IntakeTitle: Equatable {
    /// What the header shows: the lead with its trailing period or clause mark dropped (titles
    /// don't end in a period, HIG), plus "…" when the cut fell inside a clause.
    let title: String
    /// The span of the intent the title came from, punctuation intact, so `lead + " " + rest`
    /// reads as the whole request with its whitespace folded.
    let lead: String
    /// Everything after `lead`, whitespace folded to single spaces. Empty when the title is
    /// the whole request.
    let rest: String

    /// Whether the title says everything the request does — the header then has no Request
    /// section to open.
    var isWhole: Bool { rest.isEmpty }

    /// Characters, ellipsis included. Fits one line of the header's `.title3` at the pane's
    /// ~700 pt minimum.
    static let limit = 72
    /// A clause break earlier than this makes a stub ("Fix:"), so the word cut is used instead.
    private static let minimumClause = 16
    private static let abbreviations: Set<String> = ["e.g", "i.e", "vs", "cf", "etc", "approx", "incl", "esp", "viz"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "”", "’"]
    private static let clauseBreaks = [": ", " — ", " – ", " - ", "; "]

    init(intent: String) {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.prefix { !$0.isNewline }
        let afterLine = Self.fold(trimmed.dropFirst(firstLine.count))
        let line = Array(Self.fold(firstLine))

        let end = Self.sentenceEnd(line)
        var lead = String(line[..<end])
        var rest = Self.join(Self.fold(line[end...]), afterLine)
        var ellipsis = false

        if lead.count > Self.limit {
            let sentenceRest = rest
            if let cut = Self.clauseBreak(in: lead) {
                rest = Self.join(String(lead[cut.upperBound...]), sentenceRest)
                lead = String(lead[..<cut.lowerBound]) + lead[cut].trimmingCharacters(in: .whitespaces)
                if lead.hasSuffix("—") || lead.hasSuffix("–") || lead.hasSuffix("-") {
                    // A dash belongs to neither side as a lead-in; keep it with the rest instead.
                    let dash = String(lead.removeLast())
                    rest = Self.join(dash, rest)
                }
            } else if let comma = Self.lastComma(in: lead) {
                // A phrase boundary: the list row's bold lead-in then ends where a phrase does,
                // not mid-phrase ("…monorepos where | the graph").
                rest = Self.join(String(lead[comma.upperBound...]), sentenceRest)
                lead = String(lead[..<comma.lowerBound]) + ","
                ellipsis = true
            } else {
                let chars = Array(lead)
                // Room for the ellipsis; the space after the last whole word is where it cuts.
                let window = chars[..<(Self.limit - 1)]
                let space = chars[Self.limit - 1] == " " ? Self.limit - 1 : window.lastIndex(of: " ")
                let cut = space ?? Self.limit - 1
                rest = Self.join(Self.fold(chars[cut...]), sentenceRest)
                lead = String(chars[..<cut])
                ellipsis = true
            }
        }

        var title = lead
        if ellipsis {
            while let last = title.last, !(last.isLetter || last.isNumber || Self.closers.contains(last)) { title.removeLast() }
            title += "…"
        } else if title.hasSuffix(":") || title.hasSuffix(";") || (title.hasSuffix(".") && !title.hasSuffix("...")) {
            title.removeLast()
        }
        self.title = title
        self.lead = lead
        self.rest = rest
    }


    // MARK: - Cuts

    /// The index just past the first sentence of `line` (its terminator and any closing quote
    /// or paren), or `line.endIndex`. A terminator ends a sentence only when whitespace follows
    /// and the next word doesn't start lowercase — so "2.5", "v1.3.1", URLs and "e.g. icons"
    /// all stay whole — and the word it ends isn't a known abbreviation ("vs. Postgres").
    private static func sentenceEnd(_ line: [Character]) -> Int {
        var i = 0
        while i < line.count {
            guard ".!?…".contains(line[i]) else { i += 1; continue }
            var end = i + 1
            while end < line.count, closers.contains(line[end]) || ".!?".contains(line[end]) { end += 1 }
            guard end < line.count else { return line.count }
            guard line[end] == " ", end + 1 < line.count, !line[end + 1].isLowercase else { i = end; continue }
            if line[i] == "." {
                let word = line[..<i].reversed().prefix { $0 != " " && $0 != "(" }
                if abbreviations.contains(String(word.reversed()).lowercased()) { i = end; continue }
            }
            return end
        }
        return line.count
    }

    /// The first clause break inside the title's room that leaves a title worth reading.
    private static func clauseBreak(in sentence: String) -> Range<String.Index>? {
        clauseBreaks.compactMap { sentence.range(of: $0) }
            .filter { r in
                let at = sentence.distance(from: sentence.startIndex, to: r.lowerBound)
                return at >= minimumClause && at <= limit
            }
            .min { $0.lowerBound < $1.lowerBound }
    }

    /// The last ", " that leaves the title (with its ellipsis) inside `limit` and past a stub.
    private static func lastComma(in sentence: String) -> Range<String.Index>? {
        guard let r = sentence.range(of: ", ", options: .backwards,
                                     range: sentence.startIndex..<sentence.index(sentence.startIndex, offsetBy: limit - 1)),
              sentence.distance(from: sentence.startIndex, to: r.lowerBound) >= minimumClause
        else { return nil }
        return r
    }

    private static func fold<S: StringProtocol>(_ text: S) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func fold(_ chars: ArraySlice<Character>) -> String { fold(String(chars)) }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}
