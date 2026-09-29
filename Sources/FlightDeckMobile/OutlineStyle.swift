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
}
