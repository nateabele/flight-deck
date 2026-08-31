import XCTest
@testable import FlightDeck

/// The IOKit call is injected out in every test here. A real
/// `IOPMAssertionDeclareUserActivity` would wake the machine running the suite.
final class DisplayWakerTests: XCTestCase {
    /// Drawable after `flipsAfter` polls, so "wake, then become drawable" is expressible
    /// without a display. A class because the waker holds it by value.
    private final class Probe: DisplayInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var polls = 0
        var flipsAfter: Int
        init(flipsAfter: Int) { self.flipsAfter = flipsAfter }
        var isDrawable: Bool {
            lock.lock(); defer { lock.unlock() }
            polls += 1
            return polls > flipsAfter
        }
    }

    /// A class, not a captured `var`: `declareUserActivity` is `@Sendable`, and capturing a
    /// mutable local in one is a compile error under Swift 6.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeWaker(probe: Probe, declared: Counter) -> DisplayWaker {
        DisplayWaker(
            display: probe,
            pollInterval: 0.001,
            sleep: { _ in },
            declareUserActivity: { declared.increment() }
        )
    }

    /// The awake case must cost nothing: no assertion, no sleeping. Every creation from the
    /// Mac itself takes this path.
    func testAlreadyDrawableReturnsImmediatelyWithoutDeclaringActivity() {
        let declarations = Counter()
        let waker = makeWaker(probe: Probe(flipsAfter: 0), declared: declarations)
        XCTAssertTrue(waker.wakeAndWaitForDrawable(timeout: 1.5))
        XCTAssertEqual(declarations.count, 0, "an awake display must not be poked")
    }

    /// The measured behaviour: the wake is asynchronous, so the drawable arrives some polls
    /// after the declaration rather than with it.
    func testWakesAndWaitsUntilDrawable() {
        let declarations = Counter()
        let waker = makeWaker(probe: Probe(flipsAfter: 3), declared: declarations)
        XCTAssertTrue(waker.wakeAndWaitForDrawable(timeout: 1.5))
        XCTAssertEqual(declarations.count, 1)
    }

    /// A display that cannot wake — clamshell, none attached — must be given up on, not
    /// waited for forever, because this blocks the main actor.
    func testGivesUpAtTheTimeout() {
        let waker = makeWaker(probe: Probe(flipsAfter: .max), declared: Counter())
        XCTAssertFalse(waker.wakeAndWaitForDrawable(timeout: 0.05))
    }

    /// The default must be inert: this is what keeps the suite from waking a real display.
    func testNeverWakingDisplayDoesNothing() {
        XCTAssertFalse(NeverWakingDisplay().wakeAndWaitForDrawable(timeout: 1.5))
    }
}
