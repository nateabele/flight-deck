import XCTest
@testable import FlightDeck

/// A provider that is present but makes no surface. Lifted out of `PhonePromptDispatchTests`
/// so it has one home rather than a second copy: tests that need to distinguish "no provider
/// at all" (`provider: nil`) from "a real provider that libghostty simply could not draw
/// through right now" — `DisplayDrawableGuardTests`'s whole point — need exactly this shape.
final class StubProvider: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
    func tick() {}
}

/// A display that is always drawable. Lifted beside `StubProvider` because guarding
/// `createSession`/`newSession(in:)` on `canCreateTerminal` (R1) means every fixture that
/// supplies a real provider now depends on `store.display` too — without this, those fixtures
/// silently inherit whatever the *host machine's* real display happens to be doing right now.
struct DrawableDisplay: DisplayInspecting {
    var isDrawable: Bool = true
}
