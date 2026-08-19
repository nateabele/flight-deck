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
    /// shift on top of whatever modifiers were recorded.
    var key: String
    /// `NSEvent.ModifierFlags` raw value, masked to the device-independent bits. Unmasked
    /// flags carry device-dependent bits and caps lock, which would make two otherwise
    /// identical chords compare unequal across launches.
    var modifiers: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
            .rawValue
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
