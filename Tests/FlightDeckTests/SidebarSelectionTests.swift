import XCTest
@testable import FlightDeck

final class SidebarSelectionTests: XCTestCase {
    func testProjectIDRoutesToProject() {
        let p = UUID()
        XCTAssertEqual(SidebarSelection.route(p, projectIDs: [p]), .project(p))
    }

    func testSessionIDRoutesToSession() {
        let s = UUID()
        XCTAssertEqual(SidebarSelection.route(s, projectIDs: [UUID()]), .session(s))
    }

    func testNilRoutesToNoSession() {
        XCTAssertEqual(SidebarSelection.route(nil, projectIDs: []), .session(nil))
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
