import Foundation

/// The arithmetic behind the global terminal text size — pure, no AppKit and no libghostty
/// imports, so it is exercised without a live surface.
///
/// libghostty has no font-size getter and no font-size *action*: `font_size` is write-only at
/// surface creation (`0` meaning "inherit the config default"), but `set_font_size:<points>`
/// exists as a binding action. So the app owns the number and sets it absolutely — see
/// `FontSizeCommands` for why that, not counting increments, is what keeps every open surface
/// in sync with `Preferences.terminalFontSize`.
enum TerminalFontSize {
    static let step: Float = 1
    static let range: ClosedRange<Float> = 4...96 // sanity rail; libghostty clamps too

    /// `stored` is `Preferences.terminalFontSize`; `nil` resolves to `d`, the provider's
    /// configured default.
    static func resolved(_ stored: Float?, default d: Float) -> Float {
        stored ?? d
    }

    static func bigger(_ current: Float) -> Float {
        (current + step).clamped(to: range)
    }

    static func smaller(_ current: Float) -> Float {
        (current - step).clamped(to: range)
    }

    /// The libghostty binding action string for an absolute set, e.g. `set_font_size:14.0`.
    /// Formatted with an explicit decimal — not string interpolation of a `Float` — so the
    /// string libghostty parses is predictable.
    static func action(points: Float) -> String {
        String(format: "set_font_size:%.1f", points)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
