import AppKit

struct ShortcutItem: Equatable, Identifiable {
    let title: String
    let chord: String
    var id: String { title + "\u{0}" + chord }
}

struct ShortcutGroup: Equatable, Identifiable {
    let title: String
    let items: [ShortcutItem]
    var id: String { title }
}

/// The ⌘⇧/ overlay's contents, derived from the main menu rather than a hand-kept list: a list
/// drifts the first time someone adds a menu item, and the per-agent ⌘N variants are built at
/// runtime so no static list could name them. Pure over `MenuNode` so it tests without AppKit's
/// menu machinery; `ShortcutCatalog+AppKit.swift` adapts `NSMenu`.
enum ShortcutCatalog {
    struct MenuNode {
        let title: String
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
        let isHidden: Bool
        let children: [MenuNode]
    }

    static func groups(from topLevel: [MenuNode]) -> [ShortcutGroup] {
        topLevel.compactMap { menu in
            let items = flatten(menu.children)
            return items.isEmpty ? nil : ShortcutGroup(title: menu.title, items: items)
        }
    }

    private static func flatten(_ nodes: [MenuNode]) -> [ShortcutItem] {
        nodes.flatMap { node -> [ShortcutItem] in
            guard !node.isHidden else { return [] }
            if !node.children.isEmpty { return flatten(node.children) }
            guard !node.keyEquivalent.isEmpty else { return [] }
            return [ShortcutItem(title: node.title,
                                 chord: chord(key: node.keyEquivalent, modifiers: node.modifiers))]
        }
    }

    /// ⌃⌥⇧⌘ then the key — the order the menu bar itself draws. An upper-case key equivalent
    /// means ⇧ even without the flag: that is how AppKit encodes a shifted letter.
    static func chord(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var mods = modifiers
        if key.count == 1, key != key.lowercased() { mods.insert(.shift) }
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        return out + glyph(for: key)
    }

    private static func glyph(for key: String) -> String {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else {
            return key.uppercased()
        }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case 0x0D, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x09: return "⇥"
        case 0x08, 0x7F: return "⌫"
        case NSDeleteFunctionKey: return "⌦"
        case 0x20: return "Space"
        case NSF1FunctionKey...NSF20FunctionKey:
            return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        default: return key.uppercased()
        }
    }

    private static let modifierGlyphs: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    /// A chord as the overlay draws it: one keycap per modifier, then one for the key. The key
    /// stays whole because it can be several characters ("F12", "Space"); splitting the chord
    /// per character would draw F, 1, 2 as three keys.
    static func keycaps(for chord: String) -> [String] {
        let modifiers = chord.prefix { modifierGlyphs.contains($0) }
        let key = chord.dropFirst(modifiers.count)
        return modifiers.map(String.init) + (key.isEmpty ? [] : [String(key)])
    }

    /// Splits the groups into two columns at the cut that best balances their heights, keeping
    /// menu order so the left column still reads first. A fixed two-column grid instead pairs
    /// groups row by row, so a long group leaves a hole beside every short one next to it.
    /// Ties go to the fuller left column, which is where the eye starts.
    static func twoColumns(_ groups: [ShortcutGroup]) -> [[ShortcutGroup]] {
        // A header costs about a row, so it counts as one.
        let heights = groups.map { $0.items.count + 1 }
        let total = heights.reduce(0, +)
        var best = 0
        var bestHeight = Int.max
        var left = 0
        for cut in 0...groups.count {
            if cut > 0 { left += heights[cut - 1] }
            let tallest = max(left, total - left)
            if tallest <= bestHeight { best = cut; bestHeight = tallest }
        }
        return [Array(groups[..<best]), Array(groups[best...])]
    }

    /// The SF Symbol drawn beside a group header. Keyed by the menu's title, so a menu nothing
    /// here knows about still gets the generic glyph rather than a gap where the icon goes.
    static func symbol(forGroup title: String) -> String {
        switch title {
        case "File": return "doc"
        case "Edit": return "pencil"
        case "View": return "eye"
        case "Window": return "macwindow"
        case "Help": return "questionmark.circle"
        case "Tools": return "wrench.and.screwdriver"
        default: return "command"
        }
    }

    static func filter(_ groups: [ShortcutGroup], query: String) -> [ShortcutGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let hits = group.items.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || $0.chord.localizedCaseInsensitiveContains(needle)
            }
            return hits.isEmpty ? nil : ShortcutGroup(title: group.title, items: hits)
        }
    }
}
