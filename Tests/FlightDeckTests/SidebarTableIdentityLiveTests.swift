import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// `SidebarTableIdentityTests` (in `SidebarClickIntentTests.swift`) proves `isSidebarTable`
/// against hand-built `NSSplitView`/`NSTableView`/`SidebarTableMarker.MarkerView` trees, but that
/// only tests the rule's logic — it assumes `NavigationSplitView` actually puts an `NSSplitView`
/// between the window and the sidebar's table at all. If that assumption were wrong, the hand-
/// built trees would still pass while the real sidebar silently failed `isSidebarTable` and every
/// mouse/keyboard path in `SidebarInputMonitor` went dead. This hosts the real shape —
/// `RootView`'s `NavigationSplitView` (confirmed against `RootView.swift`: a plain SwiftUI
/// `NavigationSplitView`, no `.navigationSplitViewStyle`, no AppKit `NSSplitViewController`
/// override anywhere) and `ProjectView`'s nested `HSplitView` — to check that assumption directly.
///
/// This is also what CAUGHT the previous version of `isSidebarTable`'s bug before it shipped: it
/// checked "the FIRST pane of the outermost split", and on this SDK that is provably false — see
/// `isSidebarTable`'s doc comment for the six-subviews finding this test produced.
final class SidebarTableIdentityLiveTests: XCTestCase {
    /// Every `NSTableView` under `view`, depth-first.
    private func collectTables(_ view: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        if let table = view as? NSTableView { result.append(table) }
        for subview in view.subviews { result.append(contentsOf: collectTables(subview)) }
        return result
    }

    @MainActor
    func testTheRealNavigationSplitViewShapeMakesTheSidebarListIdentifiable() throws {
        // Mirrors RootView (NavigationSplitView { sidebar List } detail: { ProjectView }) and
        // ProjectView.intakeSplitView (HSplitView { Intakes List, detail Group }) — a 2-row
        // sidebar list and a 1-row Intakes list, so the two tables can be told apart by row
        // count independently of `isSidebarTable`, which is the thing under test. The marker is
        // attached exactly the way `SessionSidebar` attaches it — `.background()` on the List,
        // never inside a row.
        let root = NavigationSplitView {
            List {
                Text("a")
                Text("b")
            }
            .background(SidebarTableMarker())
        } detail: {
            HSplitView {
                List {
                    Text("x")
                }
                Text("d")
            }
        }
        .frame(width: 900, height: 600)

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        // Off-screen and never ordered front: materializing AppKit-backed SwiftUI content needs
        // a window that exists and has had layout passes, not one on screen. `.borderless` plus a
        // coordinate far outside any display keeps this from stealing focus or flashing on screen
        // if a display is attached — see `ShapingViewRenderTests.render` for the sibling
        // technique that DOES order front, because it needs `layer.render(in:)` to produce
        // pixels; this test only needs the AppKit view tree, so it does not.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host

        // SwiftUI materializes its AppKit backing (here, List's NSTableView) lazily across
        // layout passes, not synchronously on assignment. Repeated layout + a run-loop turn each
        // time is what lets that settle — five passes were enough in every run observed; there is
        // no signal to wait on instead, so this is a budget, not a guarantee.
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let tables = collectTables(host)
        guard !tables.isEmpty else {
            throw XCTSkip(
                "NavigationSplitView's List did not materialize an NSTableView in this headless "
                + "host — isSidebarTable's assumption could not be checked against the real shape."
            )
        }

        let sidebarCandidates = tables.filter { SidebarInputMonitor.isSidebarTable($0) }
        XCTAssertEqual(
            sidebarCandidates.count, 1,
            "expected exactly one table to read as the sidebar; got \(sidebarCandidates.count) "
            + "of \(tables.count) total tables (row counts: \(tables.map { $0.numberOfRows }))"
        )
        XCTAssertEqual(
            sidebarCandidates.first?.numberOfRows, 2,
            "the table isSidebarTable picked out should be the 2-row sidebar List, not the "
            + "1-row Intakes-shaped List"
        )

        window.contentView = nil
    }
}
