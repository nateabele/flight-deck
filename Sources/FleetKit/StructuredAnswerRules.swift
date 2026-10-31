import Foundation

/// The phone's copy of IntakeKit's `StructuredQuestion.isComplete` and `initialAnswer`, over the
/// wire types, so the Send button agrees with the Mac. The Mac stays authoritative: it refuses
/// an answer it cannot use (`invalid_answer`). `kind` is a string on the wire, so a kind this
/// build does not know is treated as text.
extension WireStructuredQuestion {
    private static func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Multi and toggle are always complete: "nothing ticked" and "off" are real answers.
    public func isComplete(_ a: WireStructuredAnswer) -> Bool {
        switch kind {
        case "single": a.selected.count == 1 || (a.selected.isEmpty && Self.nonBlank(a.other) != nil)
        case "multi", "toggle": true
        default: Self.nonBlank(a.other) != nil
        }
    }

    /// Recommended options preselected. A toggle is off unless recommended (its one option's id
    /// being selected means Yes).
    public var initialAnswer: WireStructuredAnswer {
        let valid = Set(options.map(\.id))
        var picked = recommended.filter { valid.contains($0) }
        switch kind {
        case "single", "toggle": picked = Array(picked.prefix(1))
        case "multi": break
        default: picked = []
        }
        return WireStructuredAnswer(questionID: id, selected: picked, other: nil)
    }
}
