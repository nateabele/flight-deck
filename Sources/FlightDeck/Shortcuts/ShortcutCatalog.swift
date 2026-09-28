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
        case 0x20: return "Space"
        default: return key.uppercased()
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
