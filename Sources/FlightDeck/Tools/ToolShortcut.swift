import AppKit

/// A recorded chord, stored in `NSEvent`'s vocabulary rather than SwiftUI's `EventModifiers`.
///
/// That choice is what makes the Tools menu possible at all: these values are assigned
/// straight onto `NSMenuItem.keyEquivalent` / `keyEquivalentModifierMask`, and the menu has to
/// be AppKit because SwiftUI cannot vary a `.keyboardShortcut` at runtime (see
/// `SessionCommands`) while a user-recorded chord is dynamic by definition.
struct ToolShortcut: Codable, Equatable {
    /// Always lowercase. `NSMenuItem.keyEquivalent` is case-sensitive, and an uppercase letter
    /// there means "shift is part of the equivalent" — so storing "O" would silently demand
    /// shift on top of whatever modifiers were recorded. This is enforced on both the recording
    /// path (init) and the decode path (init(from:)) so that un-normalized blobs in UserDefaults
    /// cannot bypass this invariant.
    private(set) var key: String
    /// Only the four menu-meaningful modifiers: command, control, option, shift. Device-dependent
    /// bits (function, numeric pad) and caps lock are stripped, so an otherwise-identical chord
    /// remains equal across launches (caps lock state differs between reboots; device bits differ
    /// between machines). This is enforced on both the recording path (init) and the decode path
    /// (init(from:)) so that un-normalized blobs in UserDefaults cannot bypass this invariant.
    private(set) var modifiers: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers
            .intersection([.command, .control, .option, .shift])
            .rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKey = try container.decode(String.self, forKey: .key)
        let rawModifiers = try container.decode(UInt.self, forKey: .modifiers)
        // Apply the same normalization as the memberwise init: decode could carry un-normalized
        // values from UserDefaults edits or older app versions.
        let flags = NSEvent.ModifierFlags(rawValue: rawModifiers)
        self.init(key: rawKey, modifiers: flags)
    }

    enum CodingKeys: String, CodingKey {
        case key
        case modifiers
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// The order macOS renders modifiers in, matching `NewSessionAffordance.display`.
    var displayString: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option) { s += "⌥" }
        if modifierFlags.contains(.shift) { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}
