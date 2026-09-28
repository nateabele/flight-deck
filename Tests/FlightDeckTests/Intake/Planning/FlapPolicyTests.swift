import XCTest
@testable import FlightDeck

/// The maintainer's rule (spec §5.3): the split-flap plays once, when a text first appears on a surface —
/// never on re-render, scroll, resize, re-hover or an unchanged value, and never under Reduce Motion.
@MainActor
final class FlapPolicyTests: XCTestCase {
    /// Stands in for `IntakeService.flapPolicy(for:)` (Task 5): one policy per intake, outliving
    /// the views that consult it, which is what keeps a recreated view from replaying.
    @MainActor private final class PolicyHolder {
        private var policies: [UUID: FlapPolicy] = [:]
        func policy(for intake: UUID) -> FlapPolicy {
            if let existing = policies[intake] { return existing }
            let made = FlapPolicy()
            policies[intake] = made
            return made
        }
    }

    func testFirstAppearanceFlaps() {
        XCTAssertTrue(FlapPolicy().shouldFlap(surface: "board.now", text: "Refine 2", reduceMotion: false))
    }

    func testSameTextNeverFlapsAgain() {
        let holder = PolicyHolder()
        let intake = UUID()
        XCTAssertTrue(holder.policy(for: intake).shouldFlap(surface: "board.now", text: "Refine 2", reduceMotion: false))
        // A re-render of the same view.
        XCTAssertFalse(holder.policy(for: intake).shouldFlap(surface: "board.now", text: "Refine 2", reduceMotion: false))
        // The view recreated after a list-selection change looks the policy up afresh.
        let again = holder.policy(for: intake)
        XCTAssertFalse(again.shouldFlap(surface: "board.now", text: "Refine 2", reduceMotion: false))
        XCTAssertFalse(again.shouldFlap(surface: "board.now", text: "Refine 2", reduceMotion: false))
        // A different intake has its own memory.
        XCTAssertTrue(holder.policy(for: UUID()).shouldFlap(surface: "board.now", text: "Refine 2", reduceMotion: false))
    }

    func testNewTextFlaps() {
        let policy = FlapPolicy()
        XCTAssertTrue(policy.shouldFlap(surface: "board.now", text: "Refine 2", reduceMotion: false))
        XCTAssertTrue(policy.shouldFlap(surface: "board.now", text: "Refine 3", reduceMotion: false))
        XCTAssertFalse(policy.shouldFlap(surface: "board.now", text: "Refine 3", reduceMotion: false))
        // The same text on another surface is a first appearance there.
        XCTAssertTrue(policy.shouldFlap(surface: "board.stops", text: "Refine 3", reduceMotion: false))
    }

    func testReduceMotionNeverFlaps() {
        let policy = FlapPolicy()
        XCTAssertFalse(policy.shouldFlap(surface: "board.now", text: "Refine 2", reduceMotion: true))
        XCTAssertFalse(policy.shouldFlap(surface: "board.now", text: "Refine 3", reduceMotion: true))
        // The text still appeared: switching Reduce Motion off later must not replay it.
        XCTAssertFalse(policy.shouldFlap(surface: "board.now", text: "Refine 3", reduceMotion: false))
    }

    func testHoverCardFlapsOnceThenNot() {
        let policy = FlapPolicy()
        XCTAssertTrue(policy.shouldFlap(surface: "card.refine-2", text: "Refine 2", reduceMotion: false))
        XCTAssertFalse(policy.shouldFlap(surface: "card.refine-2", text: "Refine 2", reduceMotion: false))
    }
}
