import Foundation

/// Reads a plan fence's info string: `fd-visual id=<id> [pending]`. The editor's `MarkdownStyler`
/// uses this; the phone's reader can too, so the two cannot disagree about which blocks are
/// visuals.
///
/// IntakeKit keeps a copy (`PlanVisualFence`) for the release export, because it cannot import
/// FleetKit. `VisualFenceInfoCrossCheckTests` pins both to the same cases.
public enum VisualFenceInfo {
    /// The id rule: `[a-z0-9][a-z0-9._-]*`, at most 64 bytes. Lowercase only, because on
    /// case-insensitive APFS `Foo` and `foo` would share a folder. The id is a folder name
    /// under `visuals/`, so it must never be able to leave it.
    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64 else { return false }
        for (i, b) in id.utf8.enumerated() {
            if (b >= 97 && b <= 122) || (b >= 48 && b <= 57) { continue }
            if i > 0, b == 45 || b == 95 || b == 46 { continue }   // - _ . after the first character
            return false
        }
        return true
    }

    /// nil for any other info string, including a malformed `fd-visual` one: it stays an
    /// ordinary code block rather than a visual pointing nowhere.
    public static func parse(_ info: String) -> (id: String, pending: Bool)? {
        let words = info.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard words.first == "fd-visual" else { return nil }
        var id: String?
        var pending = false
        for word in words.dropFirst() {
            if word.hasPrefix("id=") { id = String(word.dropFirst(3)) } else if word == "pending" { pending = true }
        }
        guard let id, isValidID(id) else { return nil }
        return (id, pending)
    }
}
