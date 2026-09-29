import FleetKit
import Foundation

enum OutlineStyle {
    static func subline(_ s: WireSection) -> String? {
        if s.diverging { return "still moving" }
        return s.settledSince.map { "still since \($0)" }
    }

    /// Pending (unconsumed, located) notes per section, keyed by the section heading's block.
    static func noteCounts(_ notes: [WireNote], outline: [WireSection]) -> [Int: Int] {
        let starts = outline.map(\.blockIndex).sorted()
        var counts: [Int: Int] = [:]
        for note in notes where !note.consumed {
            guard let block = note.blockIndex, let section = starts.last(where: { $0 <= block }) else { continue }
            counts[section, default: 0] += 1
        }
        return counts
    }

    /// The label a note carries in the read-only sheet. A comment with no text is a bare
    /// highlight; an unknown kind (a newer Mac) degrades to "Note" rather than showing raw wire text.
    static func kindName(_ kind: String, text: String) -> String {
        switch kind {
        case "comment": text.isEmpty ? "Highlight" : "Comment"
        case "question": "Question"
        case "mustChange": "Must change"
        case "replace": "Replace"
        case "delete": "Delete"
        default: "Note"
        }
    }
}
