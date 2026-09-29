import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The collapsed Intakes list's pure parts: each state's mark (`IntakeRailMark`) and the ↑/↓
/// selection walk (`IntakeRailNavigation`).
final class IntakeRailTests: XCTestCase {
    /// Spelled out rather than `CaseIterable` (IntakeKit doesn't conform): the switch in
    /// `IntakeRailMark.mark(for:)` is what fails to compile on a new case; this list is what
    /// makes the tests below cover it.
    static let every: [IntakeState] = [.triaging, .needsAnswers, .awaitingChoice, .shaping, .parked, .review,
                                       .releasing, .released, .partiallyReleased, .failed, .interrupted, .discarded]

    func testEveryStateHasItsOwnRealSymbol() {
        let symbols = Self.every.map { IntakeRailMark.mark(for: $0).symbol }
        XCTAssertEqual(Set(symbols).count, Self.every.count, "two states sharing a glyph can't be told apart in the rail: \(symbols)")
        for (state, symbol) in zip(Self.every, symbols) {
            // A misspelled SF Symbol name draws nothing at all — an empty circle in the rail.
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(state): no SF Symbol \(symbol)")
        }
    }

    /// The pill's colour language, never a second one: the rail and the list must agree on what
    /// is orange.
    func testTintIsThePills() {
        for state in Self.every {
            XCTAssertEqual(IntakeRailMark.mark(for: state).tint, IntakeStatePill.tint(for: state), "\(state)")
        }
    }

    /// The states that want the human are a solid disc — the one thing a glance down the rail
    /// has to find — and exactly those: the same set `IntakeState.needsAttention` (the
    /// sidebar badge) counts, and every one of them orange.
    func testAttentionStatesAreFilled() {
        for state in Self.every {
            let mark = IntakeRailMark.mark(for: state)
            XCTAssertEqual(mark.filled, state.needsAttention, "\(state)")
            if mark.filled { XCTAssertEqual(mark.tint, .orange, "\(state)") }
        }
    }

    /// VoiceOver reads a rail row as its title and its state, the pill's words.
    func testAccessibilityLabelIsTitleAndState() {
        var intake = Intake(projectPath: "/p", intent: "Add a dark mode toggle. It should follow the system by default.")
        intake.state = .needsAnswers
        XCTAssertEqual(IntakeRailMark.accessibilityLabel(for: intake), "Add a dark mode toggle, needs answers")
        intake.state = .released
        intake.release = ReleaseRecord(releasedAt: Date(), appliedSteps: 1, idMap: [:])
        XCTAssertEqual(IntakeRailMark.accessibilityLabel(for: intake), "Add a dark mode toggle, released · 1 step")
    }

    // MARK: - Navigation

    private let ids = [UUID(), UUID(), UUID()]

    func testArrowsWalkTheRowsAndStopAtTheEnds() {
        XCTAssertEqual(IntakeRailNavigation.move(ids[0], by: 1, in: ids), ids[1])
        XCTAssertEqual(IntakeRailNavigation.move(ids[1], by: -1, in: ids), ids[0])
        // Clamped, as a List is: ↓ on the last row stays put rather than wrapping to the top.
        XCTAssertEqual(IntakeRailNavigation.move(ids[2], by: 1, in: ids), ids[2])
        XCTAssertEqual(IntakeRailNavigation.move(ids[0], by: -1, in: ids), ids[0])
    }

    func testArrowsWithNothingSelectedStartAtTheNearEnd() {
        XCTAssertEqual(IntakeRailNavigation.move(nil, by: 1, in: ids), ids[0])
        XCTAssertEqual(IntakeRailNavigation.move(nil, by: -1, in: ids), ids[2])
        // A selection the rail no longer lists (discarded) counts as none.
        XCTAssertEqual(IntakeRailNavigation.move(UUID(), by: 1, in: ids), ids[0])
        XCTAssertNil(IntakeRailNavigation.move(nil, by: 1, in: []))
    }
}
