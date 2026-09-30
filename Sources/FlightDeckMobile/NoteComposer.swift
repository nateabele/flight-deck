import FleetKit
import Foundation

/// The note drafting rules: which kinds exist, when one can be added, and what goes on the wire.
enum NoteComposer {
    static let kinds: [(id: String, title: String)] = [
        ("comment", "Comment"), ("question", "Question"), ("mustChange", "Must change"),
        ("replace", "Replace"), ("delete", "Delete"), ("highlight", "Highlight"),
    ]

    /// A highlight carries no text of its own; every other kind needs some.
    static func canAdd(kind: String, text: String) -> Bool {
        kind == "highlight" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Mac has no "highlight" kind: it is a comment on the selection, sent at once.
    static func wire(kind: String) -> (kind: String, sendsImmediately: Bool) {
        kind == "highlight" ? ("comment", true) : (kind, false)
    }

    static func notesAllowed(detail: WireIntakeDetail?) -> Bool {
        detail?.steer == true && detail?.summary.state == "shaping"
    }
}
