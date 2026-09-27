import XCTest
@testable import FlightDeck

/// While a project view fills the detail column, the selected session is still set — it is
/// what the column falls back to — but it is hidden. ⌘W, ⌘R and Return-to-rename used to act
/// on that hidden session: ⌘W closed a terminal the user could not see.
@MainActor
final class ProjectViewShortcutTests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/w/a", isDirectory: true)
    private let projectB = URL(fileURLWithPath: "/w/b", isDirectory: true)

    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, _, done in done(nil) }
        return store
    }

    func testCloseWithAProjectViewShownClosesTheViewNotTheSession() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        store.selectProject(store.repos[0].id)

        XCTAssertTrue(store.closeSelectedSession())

        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [session.id])
    }

    func testRenameHasNoTargetWhileAProjectViewIsShown() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        XCTAssertEqual(store.renamableSessionID, session.id)

        store.selectProject(store.repos[0].id)

        XCTAssertNil(store.renamableSessionID)
    }

    /// A stale id left behind here made `isViewed` false for the terminal actually on screen,
    /// so it collected unread marks while the user was looking straight at it.
    func testClosingTheViewedProjectClearsTheProjectSelection() {
        let store = makeStore()
        store.newSession(in: projectA)
        store.newSession(in: projectB)   // selected, and survives the close below
        let a = store.repos.first { $0.url.standardizedFileURL == projectA.standardizedFileURL }!.id
        store.selectProject(a)

        store.closeProject(a)

        XCTAssertNil(store.selectedProjectID)
    }
}
