import AppKit

/// Full names first (spec §5.3): a label shows its proper name ("Synthesis", "Refine 2") when that
/// fits the slot it was given, and its code ("SYN", "RF2") only when it doesn't. The decision is a
/// measurement against the real font, redone whenever the slot resizes — never a width breakpoint,
/// which is how a mockup ends up showing "SYN" in a slot with room for the whole word.
enum LabelFit {
    /// Full name when `measure(full) + padding <= width`, else code. `padding` is the breathing
    /// room a slot keeps so a name that "just fits" doesn't sit flush against its neighbour.
    static func choose(full: String, code: String, width: CGFloat, padding: CGFloat = 8,
                       measure: (String) -> CGFloat) -> String {
        measure(full) + padding <= width ? full : code
    }

    /// The width `font` actually draws a string at — the metric SwiftUI's own layout uses, so the
    /// choice agrees with what ends up on screen.
    static func measureWith(_ font: NSFont) -> (String) -> CGFloat {
        { NSAttributedString(string: $0, attributes: [.font: font]).size().width }
    }
}
