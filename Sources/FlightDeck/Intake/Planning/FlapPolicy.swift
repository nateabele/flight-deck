import Combine

/// Nate's rule (spec §5.3): the split-flap animation plays once, when a text first appears on a
/// surface — a board value changing to new text, or a card shown for the first time. It never
/// replays on re-render, scroll, resize, re-hover of the same card, or an unchanged value, and
/// Reduce Motion means no flap at all.
///
/// The memory can't live in the view: SwiftUI throws `@State` away whenever a view is recreated
/// (a list-selection change, a lazy stack scrolling a row back in), and a view-local "already
/// flapped" flag would replay the flap every time. So one policy is kept per intake, outside the
/// view tree, and every `SplitFlapText` on that intake's screens consults it.
@MainActor
final class FlapPolicy: ObservableObject {
    /// Every (surface, text) pair that has appeared. Deliberately not `@Published`: recording an
    /// appearance must not invalidate the views that asked, or the answer would re-render them
    /// outside the animation that is meant to reveal the text.
    private var seen: Set<Key> = []

    private struct Key: Hashable {
        let surface: String
        let text: String
    }

    /// True the first time `text` is shown on `surface` (a stable key like "board.now" or
    /// "card.refine-2"); false forever after for that pair. Under Reduce Motion the pair is
    /// still recorded — the text did appear — so turning Reduce Motion off later doesn't
    /// replay everything already on screen.
    func shouldFlap(surface: String, text: String, reduceMotion: Bool) -> Bool {
        let first = seen.insert(Key(surface: surface, text: text)).inserted
        return first && !reduceMotion
    }

    /// Records `text` as already shown on `surface`, with no animation. The rule is keyed to data
    /// ARRIVING, not a view mounting: `IntakeService` seeds whatever the board shows when it first
    /// observes a tape, so a value that already existed doesn't flap just because the card
    /// scrolled into view or the intake was selected. Only a value that changes while observed does.
    func seed(surface: String, text: String) {
        seen.insert(Key(surface: surface, text: text))
    }

    /// Whether `text` has already appeared on `surface`, without recording anything. A view
    /// reads this while rendering so a text about to flap starts hidden rather than drawing
    /// once in full and then flipping away.
    func hasShown(surface: String, text: String) -> Bool {
        seen.contains(Key(surface: surface, text: text))
    }
}
