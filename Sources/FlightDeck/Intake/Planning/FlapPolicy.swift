import Combine

/// The maintainer's rule (spec §5.3): the split-flap animation plays once, when a text first appears on a
/// surface — a board value changing to new text. It never replays on re-render, scroll, resize,
/// or an unchanged value, and Reduce Motion means no flap at all. A hover card is the exception
/// and never asks: it flips its name in on every open (`CardReveal`).
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

    /// True the first time `text` is shown on `surface` (a stable key like "board.now" or a tape
    /// slot's id, "refine-2"); false forever after for that pair. Under Reduce Motion the pair is
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

/// The hover card's exception to `FlapPolicy` (spec §5.3): opening a card is a reveal, not new
/// text arriving, so its full name flips in on EVERY open — short, left to right, a hardware
/// board's clatter — and never under Reduce Motion (the card only fades then).
///
/// It deliberately doesn't consult the policy. It used to, on a `card.<slot>` surface the board
/// seeded as already shown when the tape was first observed, so every slot's card drew in place
/// and never animated; a field's card flapped only on its first hover per intake.
enum CardReveal {
    /// One tile's flip, from edge-on to flat.
    static let flip: TimeInterval = 0.18
    /// The whole reveal, first tile's start to last tile's landing, at most.
    static let total: TimeInterval = 0.32
    /// Between one tile starting and the next, for short names; long names tighten it so the
    /// reveal stays inside `total`.
    static let maxStagger: TimeInterval = 0.03
    /// The card's own fade (and, with motion, a slight scale) in, and fade out.
    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.1

    static func flaps(reduceMotion: Bool) -> Bool { !reduceMotion }

    static func stagger(count: Int) -> TimeInterval {
        count > 1 ? min(maxStagger, (total - flip) / Double(count - 1)) : 0
    }

    static func duration(count: Int) -> TimeInterval {
        flip + stagger(count: count) * Double(max(0, count - 1))
    }

    /// How far tile `index` of `count` has flipped `elapsed` seconds into the reveal: 0 edge-on,
    /// 1 flat, eased out so it lands like a flap falling onto its stop.
    static func progress(index: Int, count: Int, elapsed: TimeInterval) -> Double {
        let local = min(1, max(0, (elapsed - stagger(count: count) * Double(index)) / flip))
        return 1 - (1 - local) * (1 - local) * (1 - local)
    }
}
