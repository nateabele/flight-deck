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

    /// `selectsRow`'s counterpart to `toggles(...)` above: same defaults, `inChevronZone: false`
    /// fixed, since selection is only ever a candidate outside the chevron zone.
    private func selects(
        from down: CGPoint,
        to up: CGPoint,
        downRow: String? = nil,
        upRow: String? = nil,
        clickCount: Int = 1,
        pressedRowControl: Bool = false
    ) -> Bool {
        SidebarClickIntent.selectsRow(
            downPoint: down,
            upPoint: up,
            downRow: downRow ?? row,
            upRow: upRow ?? downRow ?? row,
            clickCount: clickCount,
            pressedRowControl: pressedRowControl,
            inChevronZone: false
        )
    }

    func testAPlainClickOutsideTheChevronZoneSelects() {
        XCTAssertTrue(selects(from: CGPoint(x: 100, y: 10), to: CGPoint(x: 100, y: 10)))
    }

    func testADragOutsideTheChevronZoneDoesNotSelect() {
        XCTAssertFalse(selects(from: CGPoint(x: 100, y: 10), to: CGPoint(x: 100, y: 30)))
    }

    func testADoubleClickOutsideTheChevronZoneDoesNotSelect() {
        XCTAssertFalse(selects(
            from: CGPoint(x: 100, y: 10), to: CGPoint(x: 100, y: 10), clickCount: 2))
    }

    func testAPressOnTheCloseButtonDoesNotSelect() {
        XCTAssertFalse(selects(
            from: CGPoint(x: 100, y: 10), to: CGPoint(x: 100, y: 10), pressedRowControl: true))
    }

    func testReleasingOverADifferentRowDoesNotSelect() {
        XCTAssertFalse(selects(
            from: CGPoint(x: 100, y: 10), to: CGPoint(x: 100, y: 10),
            downRow: row, upRow: otherRow))
    }

    func testInsideTheChevronZoneAPlainClickDoesNotSelect() {
        // The mirror image of `testAPlainClickOutsideTheChevronZoneSelects`: the zone is
        // `togglesCollapse`'s job, not this one's.
        XCTAssertFalse(SidebarClickIntent.selectsRow(
            downPoint: .init(x: 8, y: 10), upPoint: .init(x: 8, y: 10),
            downRow: row, upRow: row, clickCount: 1, pressedRowControl: false,
            inChevronZone: true))
    }

    func testTogglesCollapseAndSelectsRowAreNeverBothTrue() {
        // A small table over the dimensions either rule can flip on: which zone the press
        // landed in, click vs. drag, click count, the close-button exclusion, and row identity.
        // `inChevronZone` is the only one of these the two rules disagree about, so no row of
        // this table should ever produce true from both.
        struct Case { let down, up: CGPoint; let downRow, upRow: String?; let clickCount: Int; let pressedRowControl: Bool }
        let cases: [Case] = [
            Case(down: .init(x: 8, y: 10), up: .init(x: 8, y: 10), downRow: row, upRow: row, clickCount: 1, pressedRowControl: false),
            Case(down: .init(x: 8, y: 10), up: .init(x: 8, y: 30), downRow: row, upRow: row, clickCount: 1, pressedRowControl: false),
            Case(down: .init(x: 100, y: 10), up: .init(x: 100, y: 10), downRow: row, upRow: row, clickCount: 1, pressedRowControl: false),
            Case(down: .init(x: 100, y: 10), up: .init(x: 100, y: 30), downRow: row, upRow: row, clickCount: 1, pressedRowControl: false),
            Case(down: .init(x: 8, y: 10), up: .init(x: 8, y: 10), downRow: row, upRow: row, clickCount: 2, pressedRowControl: false),
            Case(down: .init(x: 100, y: 10), up: .init(x: 100, y: 10), downRow: row, upRow: row, clickCount: 2, pressedRowControl: false),
            Case(down: .init(x: 8, y: 10), up: .init(x: 8, y: 10), downRow: row, upRow: row, clickCount: 1, pressedRowControl: true),
            Case(down: .init(x: 100, y: 10), up: .init(x: 100, y: 10), downRow: row, upRow: row, clickCount: 1, pressedRowControl: true),
            Case(down: .init(x: 8, y: 10), up: .init(x: 8, y: 10), downRow: row, upRow: otherRow, clickCount: 1, pressedRowControl: false),
            Case(down: .init(x: 100, y: 10), up: .init(x: 100, y: 10), downRow: row, upRow: otherRow, clickCount: 1, pressedRowControl: false),
            Case(down: .init(x: 8, y: 10), up: .init(x: 8, y: 10), downRow: nil, upRow: nil, clickCount: 1, pressedRowControl: false),
        ]
        for inChevronZone in [true, false] {
            for c in cases {
                let toggles = SidebarClickIntent.togglesCollapse(
                    downPoint: c.down, upPoint: c.up, downRow: c.downRow, upRow: c.upRow,
                    clickCount: c.clickCount, pressedRowControl: c.pressedRowControl,
                    inChevronZone: inChevronZone)
                let selects = SidebarClickIntent.selectsRow(
                    downPoint: c.down, upPoint: c.up, downRow: c.downRow, upRow: c.upRow,
                    clickCount: c.clickCount, pressedRowControl: c.pressedRowControl,
                    inChevronZone: inChevronZone)
                XCTAssertFalse(toggles && selects,
                                "toggle and select both true for \(c), inChevronZone=\(inChevronZone)")
            }
        }
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

/// Which `NSTableView` is the sidebar's — the fix for the bug where a click on `ProjectView`'s
/// Intakes list (also a table, in the same window) was treated as a click on the sidebar row at
/// the same index. See the file's "Scoping" doc comment.
///
/// Built by hand from `NSSplitView`/`NSTableView` instances with no window, the same style as
/// `SidebarPressedControlTests` above: the rule only reads the view tree, so a window would test
/// AppKit's layout rather than this one's logic.
@MainActor
final class SidebarTableIdentityTests: XCTestCase {
    /// Nests `table` a couple of levels deep under `pane`, the way a real sidebar or Intakes
    /// list nests its table inside an `NSScrollView`'s clip view — the rule has to walk past
    /// that, not just check `pane`'s immediate children.
    private func nest(_ table: NSTableView, under pane: NSView) {
        let scrollView = NSView(frame: pane.bounds)
        let clipView = NSView(frame: pane.bounds)
        scrollView.addSubview(clipView)
        clipView.addSubview(table)
        pane.addSubview(scrollView)
    }

    func testATableInTheOuterSplitsFirstPaneIsTheSidebar() {
        let outer = NSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let sidebarPane = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        let detailPane = NSView(frame: NSRect(x: 240, y: 0, width: 360, height: 400))
        outer.addSubview(sidebarPane)
        outer.addSubview(detailPane)

        let table = NSTableView()
        nest(table, under: sidebarPane)

        XCTAssertTrue(SidebarInputMonitor.isSidebarTable(table))
    }

    func testATableNestedInAnInnerSplitInsideTheOuterSplitsSecondPaneIsNotTheSidebar() {
        // `ProjectView`'s shape: the Intakes table sits in an `HSplitView` (also an
        // `NSSplitView`) that is itself the outer split's detail pane, not its sidebar pane.
        let outer = NSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let sidebarPane = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        let detailPane = NSView(frame: NSRect(x: 240, y: 0, width: 360, height: 400))
        outer.addSubview(sidebarPane)
        outer.addSubview(detailPane)

        let inner = NSSplitView(frame: detailPane.bounds)
        let intakesPane = NSView(frame: NSRect(x: 240, y: 0, width: 160, height: 400))
        let readingPane = NSView(frame: NSRect(x: 400, y: 0, width: 200, height: 400))
        inner.addSubview(intakesPane)
        inner.addSubview(readingPane)
        detailPane.addSubview(inner)

        let table = NSTableView()
        nest(table, under: intakesPane)

        XCTAssertFalse(SidebarInputMonitor.isSidebarTable(table))
    }

    func testATableInNoSplitViewAtAllIsNotTheSidebar() {
        // Settings ▸ Projects and `NSOpenPanel` are table-backed but carry no split view — the
        // scope check in `handleMouseDown`/`handleKeyDown` excludes those windows outright, but
        // this rule must also be total and answer false rather than crash or guess.
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let table = NSTableView()
        nest(table, under: plain)

        XCTAssertFalse(SidebarInputMonitor.isSidebarTable(table))
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
