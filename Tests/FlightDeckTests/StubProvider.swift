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
