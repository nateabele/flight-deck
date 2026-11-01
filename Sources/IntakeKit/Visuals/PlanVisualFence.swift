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

/// One `fd-visual` block of a plan, in plan order.
public struct PlanVisualBlock: Equatable, Sendable {
    public var id: VisualID
    public var pending: Bool
    /// The block's first non-blank body line, trimmed; nil when the body is blank.
    public var caption: String?
    /// The nearest heading line above the block ("## 3. Pairing"), nil above the first heading.
    public var section: String?
    public init(id: VisualID, pending: Bool, caption: String? = nil, section: String? = nil) {
        self.id = id; self.pending = pending; self.caption = caption; self.section = section
    }
}

extension PlanVisualFence {
    // Fence scanning follows the editor's rules: a closer has the same character, at least the
    // opener's length, and no info string; a backtick opener's info has no backtick. The release
    // export and `blocks(in:)` share these, so a block the export rewrites is a block a round sees.
    struct Fence { var char: Character; var length: Int; var info: String }

    static func fenceOpen(_ line: String) -> Fence? {
        let t = line.drop(while: { $0 == " " }).self
        guard line.count - t.count <= 3, let c = t.first, c == "`" || c == "~" else { return nil }
        let run = t.prefix(while: { $0 == c })
        guard run.count >= 3 else { return nil }
        let info = t.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        return Fence(char: c, length: run.count, info: info)
    }

    static func isClose(_ line: String, of f: Fence) -> Bool {
        guard let o = fenceOpen(line) else { return false }
        return o.char == f.char && o.length >= f.length && o.info.isEmpty
    }

    /// Every closed `fd-visual` block in `plan`, in order. A fence that never closes is not a
    /// block (the export copies it through as text), and neither is anything inside another fence.
    public static func blocks(in plan: String) -> [PlanVisualBlock] {
        var out: [PlanVisualBlock] = []
        let lines = plan.components(separatedBy: "\n")
        var section: String?
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let open = fenceOpen(line) else {
                if line.hasPrefix("#") {
                    let hashes = line.prefix { $0 == "#" }.count
                    if hashes <= 6, line.dropFirst(hashes).first == " " { section = line.trimmingCharacters(in: .whitespaces) }
                }
                i += 1
                continue
            }
            var j = i + 1
            while j < lines.count, !isClose(lines[j], of: open) { j += 1 }
            guard j < lines.count else { break }
            if let v = parse(open.info), let id = VisualID(rawValue: v.id) {
                let caption = lines[(i + 1)..<j].map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                out.append(PlanVisualBlock(id: id, pending: v.pending, caption: caption, section: section))
            }
            i = j + 1
        }
        return out
    }

    /// The visual ids a change set may cite (`ChangeSetValidator`'s `knownVisuals`): each
    /// non-pending block in `plan` with a block state (checkpoint `checkpoint`'s record first, then
    /// `block.json`) whose primary revision loads: exactly what release exports and `VisualCatalogue`
    /// lists, so a task never cites a folder that is not written. A pending placeholder has
    /// nothing to export, so a task cannot be built to match it yet. Empty, never nil, for a
    /// plan with no visuals or no plan at all.
    public static func knownVisuals(plan: String?, store: any VisualStoreReading, checkpoint: Int? = nil) -> Set<String> {
        Set(knownVisualStates(plan: plan, store: store, checkpoint: checkpoint).keys)
    }

    /// `knownVisuals` with each visual's states (its primary manifest's; `default` when it names
    /// none), for `ChangeSetValidator`'s `visualStates`.
    public static func knownVisualStates(plan: String?, store: any VisualStoreReading, checkpoint: Int? = nil) -> [String: Set<String>] {
        guard let plan else { return [:] }
        var out: [String: Set<String>] = [:]
        for b in blocks(in: plan) where !b.pending {
            guard let state = checkpoint.flatMap({ store.blockState(b.id, checkpoint: $0) }) ?? store.blockState(b.id),
                  let rev = store.revision(b.id, r: state.primary.r) else { continue }
            out[b.id.rawValue] = Set(rev.manifest.states.isEmpty ? ["default"] : rev.manifest.states)
        }
        return out
    }
}
