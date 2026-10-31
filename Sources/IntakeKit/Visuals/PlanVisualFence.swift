import Foundation

/// Reads a plan fence's info string for the release export: `fd-visual id=<id> [pending]`.
///
/// **This is a deliberate copy of FleetKit's `VisualFenceInfo`**, which the editor uses.
/// IntakeKit cannot import FleetKit, and the rule is small. `VisualFenceInfoCrossCheckTests`
/// (hosted, so it sees both) pins the two to the same cases, so they cannot drift.
public enum PlanVisualFence {
    /// nil for any other info string. An id that is not a usable folder name makes the block
    /// an ordinary code block rather than a visual pointing somewhere it should not.
    public static func parse(_ info: String) -> (id: String, pending: Bool)? {
        let words = info.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard words.first == "fd-visual" else { return nil }
        var id: String?
        var pending = false
        for word in words.dropFirst() {
            if word.hasPrefix("id=") { id = String(word.dropFirst(3)) } else if word == "pending" { pending = true }
        }
        guard let id, VisualID.isValid(id) else { return nil }
        return (id, pending)
    }
}
