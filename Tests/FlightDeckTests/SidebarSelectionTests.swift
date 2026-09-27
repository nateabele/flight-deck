import SwiftUI
import XCTest
@testable import FlightDeck

final class SidebarSelectionTests: XCTestCase {
    func testProjectIDRoutesToProject() {
        let p = UUID()
        XCTAssertEqual(SidebarSelection.route(p, projectIDs: [p], currentProject: nil), .project(p))
    }

    func testSessionIDRoutesToSession() {
        let s = UUID()
        XCTAssertEqual(
            SidebarSelection.route(s, projectIDs: [UUID()], currentProject: nil), .session(s))
    }

    func testNilRoutesToNoSessionWhenNoProjectIsSelected() {
        XCTAssertEqual(
            SidebarSelection.route(nil, projectIDs: [], currentProject: nil), .session(nil))
    }

    /// Controller ruling, fix round 4: headers are `.selectionDisabled()`, so nothing the user
    /// does to a project row legitimately produces this `nil` any more — but `List` can still
    /// echo one back on its own right after `selectProject` sets `currentProject` (nothing is
    /// tagged with the project id, so the table has nothing selected to show). Fix round 1 had
    /// this routing to `.clearProject`, which instantly undid the very selection that produced
    /// it. `.ignore` is the fix: leave both selections exactly as they were.
    func testNilWhileAProjectIsSelectedIsANoOp() {
        let p = UUID()
        XCTAssertEqual(
            SidebarSelection.route(nil, projectIDs: [], currentProject: p), .ignore)
    }

    /// The unchanged half of the same fix: with no project selected, `nil` still means "no
    /// session selected" — `currentProject` only changes the outcome when it is non-nil.
    func testNilWhileASessionIsSelectedStillClearsTheSession() {
        XCTAssertEqual(
            SidebarSelection.route(nil, projectIDs: [], currentProject: nil), .session(nil))
    }

    @MainActor func testSelectingSessionClearsProjectSelection() {
        let store = SessionStore(provider: nil, persistence: nil)
        let project = UUID()
        store.selectProject(project)
        XCTAssertEqual(store.selectedProjectID, project)
        store.selectedSessionID = UUID()
        XCTAssertNil(store.selectedProjectID)
    }

    /// Fix round 3: `ProjectHeaderRow` lost its `List` selection highlight (see
    /// `SessionSidebar`'s `selectionBinding` comment for why) and now draws its own from this
    /// pure helper instead. Routed through `store.selectProject` rather than calling the helper
    /// directly, so this also covers the wiring — not just the equality check underneath it.
    @MainActor func testSelectingProjectDrivesTheHeaderRowsSelectedState() {
        let store = SessionStore(provider: nil, persistence: nil)
        let project = UUID()
        let other = UUID()
        XCTAssertFalse(ProjectHeaderRow.isSelected(repoID: project, selectedProjectID: store.selectedProjectID))

        store.selectProject(project)

        XCTAssertTrue(ProjectHeaderRow.isSelected(repoID: project, selectedProjectID: store.selectedProjectID))
        XCTAssertFalse(ProjectHeaderRow.isSelected(repoID: other, selectedProjectID: store.selectedProjectID))
    }

    /// A natively selected sidebar row is accent-filled only while its table is first responder
    /// in the key window, and system-gray otherwise — which in this app is most of the time,
    /// because the terminal holds focus. The hand-drawn header highlight must follow the same
    /// rule, or a selected project reads blue beside the gray a selected session shows in the
    /// same window state.
    func testHeaderHighlightIsEmphasizedOnlyWhenTheSidebarHasFocusInTheKeyWindow() {
        XCTAssertTrue(ProjectHeaderRow.isEmphasized(isSelected: true, sidebarFocused: true, controlActiveState: .key))
        XCTAssertFalse(ProjectHeaderRow.isEmphasized(isSelected: true, sidebarFocused: false, controlActiveState: .key))
        XCTAssertFalse(ProjectHeaderRow.isEmphasized(isSelected: true, sidebarFocused: true, controlActiveState: .active))
        XCTAssertFalse(ProjectHeaderRow.isEmphasized(isSelected: true, sidebarFocused: true, controlActiveState: .inactive))
        XCTAssertFalse(ProjectHeaderRow.isEmphasized(isSelected: false, sidebarFocused: true, controlActiveState: .key))
    }
}
