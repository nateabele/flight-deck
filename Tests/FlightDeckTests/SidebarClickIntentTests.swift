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
            pressedRowControl: pressedRowControl,
            inChevronZone: true
        )
    }

    func testClickOutsideChevronZoneDoesNotToggle() {
        let row = "p:A"
        XCTAssertFalse(SidebarClickIntent.togglesCollapse(
            downPoint: .init(x: 100, y: 10), upPoint: .init(x: 100, y: 10),
            downRow: row, upRow: row, clickCount: 1, pressedRowControl: false,
            inChevronZone: false))
    }

    func testClickInChevronZoneToggles() {
        let row = "p:A"
        XCTAssertTrue(SidebarClickIntent.togglesCollapse(
            downPoint: .init(x: 8, y: 10), upPoint: .init(x: 9, y: 10),
            downRow: row, upRow: row, clickCount: 1, pressedRowControl: false,
            inChevronZone: true))
    }

    func testChevronZoneDragStillDoesNotToggle() {
        let row = "p:A"
        XCTAssertFalse(SidebarClickIntent.togglesCollapse(
            downPoint: .init(x: 8, y: 10), upPoint: .init(x: 8, y: 30),
            downRow: row, upRow: row, clickCount: 1, pressedRowControl: false,
            inChevronZone: true))
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
                downRow: row, upRow: nil, clickCount: 1, pressedRowControl: false,
                inChevronZone: true
            )
        )
    }

    func testAnUnidentifiableRowNeverToggles() {
        // Two rows that cannot be named are not thereby "the same row".
        XCTAssertFalse(
            SidebarClickIntent.togglesCollapse(
                downPoint: CGPoint(x: 40, y: 200), upPoint: CGPoint(x: 40, y: 200),
                downRow: nil, upRow: nil, clickCount: 1, pressedRowControl: false,
                inChevronZone: true
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

/// The other half of the close-button exclusion. The rule above only forwards a `Bool`; this is
/// what decides it, and it is the half that has to be right about AppKit.
///
/// No window is needed: `NSView.convert(_:from: nil)` treats the point as window coordinates,
/// and with `row` as the root of its own tree those are the row's coordinates.
@MainActor
final class SidebarPressedControlTests: XCTestCase {
    /// A row with a 15×13 button at its trailing edge, which is where SwiftUI puts the real one.
    private func row(withButtonAt frame: NSRect, nested: Bool = false) -> NSTableRowView {
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let button = NSButton(frame: frame)
        if nested {
            // SwiftUI's real tree is row → cell view → hosting view → button, so the walk has to
            // recurse rather than check the row's immediate children.
            let cell = NSView(frame: NSRect(x: 16, y: 0, width: 248, height: 24))
            let host = NSView(frame: cell.bounds)
            button.frame = NSRect(
                x: frame.origin.x - cell.frame.origin.x, y: frame.origin.y,
                width: frame.width, height: frame.height
            )
            host.addSubview(button)
            cell.addSubview(host)
            row.addSubview(cell)
        } else {
            row.addSubview(button)
        }
        row.layoutSubtreeIfNeeded()
        return row
    }

    private let buttonFrame = NSRect(x: 249, y: 6, width: 15, height: 13)

    func testAPressInsideTheButtonFindsIt() {
        let row = row(withButtonAt: buttonFrame)

        XCTAssertTrue(SidebarInputMonitor.pressedControl(in: row, at: NSPoint(x: 256, y: 12)))
    }

    func testAPressOnTheTitleDoesNotFindTheButton() {
        let row = row(withButtonAt: buttonFrame)

        // Where a project name is, far from the trailing edge.
        XCTAssertFalse(SidebarInputMonitor.pressedControl(in: row, at: NSPoint(x: 40, y: 12)))
    }

    func testAPressJustOutsideTheButtonDoesNotFindIt() {
        let row = row(withButtonAt: buttonFrame)

        // 2pt to its leading side: the exclusion is the control's frame and nothing more, which
        // is the whole reason the guessed 32pt strip was deleted.
        XCTAssertFalse(SidebarInputMonitor.pressedControl(in: row, at: NSPoint(x: 247, y: 12)))
    }

    func testTheWalkRecursesIntoNestedViews() {
        // The real tree nests the button three deep under the row.
        let row = row(withButtonAt: buttonFrame, nested: true)

        XCTAssertTrue(SidebarInputMonitor.pressedControl(in: row, at: NSPoint(x: 256, y: 12)))
        XCTAssertFalse(SidebarInputMonitor.pressedControl(in: row, at: NSPoint(x: 40, y: 12)))
    }

    func testARowWithNoControlExcludesNothing() {
        // An un-hovered header: the button is removed from the tree, not hidden, so every point
        // in the row is fair game for the toggle.
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        row.addSubview(NSView(frame: row.bounds))

        XCTAssertFalse(SidebarInputMonitor.pressedControl(in: row, at: NSPoint(x: 256, y: 12)))
    }

    func testANonControlViewIsNotAnExclusion() {
        // A collapsed header draws a spinner; `NSProgressIndicator` is an `NSView` and not an
        // `NSControl`, so it must not suppress the toggle.
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        row.addSubview(NSProgressIndicator(frame: NSRect(x: 230, y: 6, width: 13, height: 13)))

        XCTAssertFalse(SidebarInputMonitor.pressedControl(in: row, at: NSPoint(x: 236, y: 12)))
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
