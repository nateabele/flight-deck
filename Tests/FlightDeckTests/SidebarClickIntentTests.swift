import XCTest
@testable import FlightDeck

/// The click-vs-drag rule behind the sidebar's row-wide collapse toggle. Pure by design — see
/// `SidebarInputMonitor`'s doc comment — so none of this needs a window or an `NSEvent`.
@MainActor
final class SidebarClickIntentTests: XCTestCase {
    /// `SidebarRow.id`'s shape, since that is what the rule compares.
    private let row = "p:\(UUID().uuidString)"
    private let otherRow = "p:\(UUID().uuidString)"

    private func toggles(
        from down: CGPoint,
        to up: CGPoint,
        downRow: String? = nil,
        upRow: String? = nil,
        clickCount: Int = 1,
        pressedRowControl: Bool = false
    ) -> Bool {
        SidebarClickIntent.togglesCollapse(
            downPoint: down,
            upPoint: up,
            downRow: downRow ?? row,
            upRow: upRow ?? downRow ?? row,
            clickCount: clickCount,
            pressedRowControl: pressedRowControl
        )
    }

    func testAPressThatBarelyMovesIsAClick() {
        // 3pt of travel: a hand resting on the mouse, not a drag.
        XCTAssertTrue(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 42, y: 198)))
    }

    func testAPressThatDoesNotMoveAtAllIsAClick() {
        XCTAssertTrue(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 40, y: 200)))
    }

    func testTravelBeyondTheThresholdIsADragNotAClick() {
        // Straight down the sidebar, which is the direction a reorder drag moves.
        XCTAssertFalse(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 40, y: 190)))
    }

    func testTravelIsMeasuredAsDistanceNotPerAxis() {
        // 3pt on each axis is under the threshold on either alone, and 4.24pt together.
        XCTAssertFalse(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 43, y: 203)))
    }

    func testTheDragThresholdIsFourPoints() {
        // Pinned, not inferred: the cases above still pass at 4.2 or 3.8, and this rule's whole
        // job is to sit just above hand tremor and well below a deliberate drag.
        XCTAssertEqual(SidebarClickIntent.dragThreshold, 4.0)

        let origin = CGPoint(x: 40, y: 200)
        XCTAssertTrue(toggles(from: origin, to: CGPoint(x: 40 + 3.99, y: 200)))
        XCTAssertFalse(toggles(from: origin, to: CGPoint(x: 40 + 4.0, y: 200)))
    }

    func testReleasingOverADifferentRowDoesNotToggle() {
        XCTAssertFalse(
            toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 40, y: 199),
                    downRow: row, upRow: otherRow)
        )
    }

    // The two nil cases call the rule directly: `toggles(...)` above defaults a missing row to
    // the matching one, which is convenient everywhere else and cannot express "no row".

    func testReleasingWhereNoRowCanBeIdentifiedDoesNotToggle() {
        // The pointer left the list, or the row it was on is gone.
        XCTAssertFalse(
            SidebarClickIntent.togglesCollapse(
                downPoint: CGPoint(x: 40, y: 200), upPoint: CGPoint(x: 40, y: 200),
                downRow: row, upRow: nil, clickCount: 1, pressedRowControl: false
            )
        )
    }

    func testAnUnidentifiableRowNeverToggles() {
        // Two rows that cannot be named are not thereby "the same row".
        XCTAssertFalse(
            SidebarClickIntent.togglesCollapse(
                downPoint: CGPoint(x: 40, y: 200), upPoint: CGPoint(x: 40, y: 200),
                downRow: nil, upRow: nil, clickCount: 1, pressedRowControl: false
            )
        )
    }

    func testADoubleClickDoesNotToggle() {
        // Unreachable from `SidebarInputMonitor`, which only schedules on `clickCount == 1`, but
        // the rule is pure and stays total over its inputs rather than trusting one call site.
        XCTAssertFalse(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 40, y: 200), clickCount: 2))
    }

    func testAPressOnTheCloseButtonDoesNotToggle() {
        // The hover-revealed X. Excluded by its own frame — there is no exclusion width here to
        // assert, which is the point: see `SidebarInputMonitor.pressedControl(in:at:)`.
        XCTAssertFalse(
            toggles(from: CGPoint(x: 230, y: 200), to: CGPoint(x: 230, y: 200),
                    pressedRowControl: true)
        )
    }
}

/// `SidebarRow.id` is what the rule above compares, so its two documented properties — stable
/// across a reorder, and distinct per row — are what make that comparison mean anything.
@MainActor
final class SidebarRowIdentityTests: XCTestCase {
    private func repo(_ path: String, sessions: Int) -> Repo {
        Repo(
            url: URL(fileURLWithPath: path, isDirectory: true),
            sessions: (0..<sessions).map { Session(title: "s\($0)", workingDirectory: path) }
        )
    }

    func testARowsIdentitySurvivesTheIndexItSitsAt() {
        let a = repo("/w/a", sessions: 1)
        let b = repo("/w/b", sessions: 1)

        let before = SidebarRow.rows(for: [a, b])
        let after = SidebarRow.rows(for: [b, a])

        // b's header is index 2 before and index 0 after. This is exactly the shift the monitor
        // defends against by capturing identity rather than the index it pressed.
        XCTAssertEqual(before[2].id, after[0].id)
        XCTAssertNotEqual(before[0].id, after[0].id)
    }

    func testAProjectAndItsOwnSessionRowDoNotShareAnIdentity() {
        let a = repo("/w/a", sessions: 1)
        let rows = SidebarRow.rows(for: [a])

        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }
}
