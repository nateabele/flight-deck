import Foundation

/// Whether the floating tool buttons are showing.
///
/// A value type with no clock, no timer and no view: the caller supplies "now". That is what
/// makes "fades after five idle seconds" a test that runs instantly rather than one that sleeps.
///
/// The rules: mouse movement over the terminal shows the buttons; the first keystroke hides
/// them and keeps them hidden until the mouse moves again; five seconds without movement hides
/// them on their own; hovering the cluster pins it so a button can be aimed at.
struct ToolOverlayVisibility: Equatable {
    static let idleTimeout: Duration = .seconds(5)

    private var lastMove: ContinuousClock.Instant?
    private var isHovering = false
    /// A separate flag rather than clearing `lastMove` when typing. The two designs are
    /// behaviourally identical: both fail the guard in `isVisible`, both fail in
    /// `idleDeadline`, and both are restored by `mouseMoved(at:)`. We keep the flag to
    /// represent two independent facts distinctly: `lastMove` means "when did the mouse last
    /// move" and `suppressedByTyping` means "should we hide anyway". Without this separation,
    /// nil on `lastMove` would carry two unrelated meanings ("never moved" or "user is typing"),
    /// confusing future readers about why typing means the mouse never moved.
    private var suppressedByTyping = false

    mutating func mouseMoved(at now: ContinuousClock.Instant) {
        suppressedByTyping = false
        lastMove = now
    }

    mutating func keyPressed() {
        suppressedByTyping = true
    }

    mutating func hoverChanged(_ inside: Bool) {
        isHovering = inside
    }

    func isVisible(at now: ContinuousClock.Instant) -> Bool {
        // Hover wins outright. You cannot type while deliberately hovering the cluster, and
        // the alternative — letting a stray keystroke yank the buttons out from under a
        // pointer already on its way to one — is worse.
        if isHovering { return true }
        guard !suppressedByTyping, let lastMove else { return false }
        return now - lastMove < Self.idleTimeout
    }

    /// When the overlay would next change state on its own, so the caller can schedule exactly
    /// one wake instead of polling. nil means nothing is pending.
    func idleDeadline() -> ContinuousClock.Instant? {
        guard !isHovering, !suppressedByTyping, let lastMove else { return nil }
        return lastMove.advanced(by: Self.idleTimeout)
    }
}
