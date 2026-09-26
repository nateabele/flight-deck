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

    /// Fix round 1, finding 2: ⌘-clicking the *selected project row* writes `nil` to the
    /// `List`'s selection. Without `currentProject`, that indistinguishably matched the
    /// "deselecting a session" case and zeroed `selectedSessionID` — losing which terminal
    /// was selected underneath the project view for no reason the user asked for.
    func testNilWhileAProjectIsSelectedClearsOnlyTheProject() {
        let p = UUID()
        XCTAssertEqual(
            SidebarSelection.route(nil, projectIDs: [], currentProject: p), .clearProject)
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
}
