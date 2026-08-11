import XCTest
@testable import FlightDeck

@MainActor
final class SessionCreationTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private func makeStore() -> SessionStore {
        SessionStore(provider: StubProvider())
    }

    private func titles(_ store: SessionStore) -> [String] {
        store.repos.flatMap(\.sessions).map(\.title)
    }

    /// Three sessions with the active one in the MIDDLE: an append-to-end regression
    /// would put the new session last and fail this.
    func testNewSessionBelowActiveInsertsDirectlyAfterTheActiveSession() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        let first = store.newSession(in: url)
        let middle = store.newSession(in: url)
        _ = store.newSession(in: url)

        store.selectedSessionID = middle.id
        let created = store.newSessionBelowActive()

        XCTAssertNotNil(created)
        XCTAssertEqual(
            titles(store),
            ["session 1", "session 2", "session 4", "session 3"],
            "the new session must sit directly below the active one, not at the end"
        )
        XCTAssertEqual(store.repos[0].sessions[2].id, created?.id)
        _ = first
    }

    func testNewSessionBelowActiveSelectsTheNewSession() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        _ = store.newSession(in: url)
        let created = store.newSessionBelowActive()
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    /// It inherits the ACTIVE session's project, not the first repo's.
    func testNewSessionBelowActiveUsesTheActiveSessionsProject() {
        let store = makeStore()
        _ = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let bar = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))

        store.selectedSessionID = bar.id
        let created = store.newSessionBelowActive()

        XCTAssertEqual(created?.workingDirectory, "/work/bar")
        XCTAssertEqual(store.repos.map(\.displayName), ["foo", "bar"])
        XCTAssertEqual(store.repos[1].sessions.count, 2)
    }

    func testNewSessionBelowActiveDoesNothingWithNoActiveSession() {
        let store = makeStore()
        XCTAssertNil(store.newSessionBelowActive())
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testAddProjectCreatesANewRepo() {
        let store = makeStore()
        let created = store.addProject(at: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(store.repos.map(\.displayName), ["foo"])
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    /// Dropping or adding an already-known folder adds another session to it.
    func testAddProjectOnAnExistingRepoAppendsAndActivates() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        _ = store.newSession(in: url)
        let created = store.addProject(at: url)

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
        XCTAssertEqual(store.repos[0].sessions.last?.id, created.id)
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testCreateFromMenuAddsBelowActiveWhenSessionsExist() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        _ = store.newSession(in: url)
        var prompted = false
        let created = store.createFromMenu(chooseFolder: { prompted = true; return nil })

        XCTAssertFalse(prompted, "⌘N must not prompt for a folder when a session is active")
        XCTAssertEqual(store.repos[0].sessions.count, 2)
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    /// The reroute: with nothing open, ⌘N behaves as Add Project.
    func testCreateFromMenuPromptsAndAddsProjectWhenEmpty() {
        let store = makeStore()
        var prompted = false
        let created = store.createFromMenu(chooseFolder: {
            prompted = true
            return URL(fileURLWithPath: "/work/bar", isDirectory: true)
        })

        XCTAssertTrue(prompted)
        XCTAssertEqual(store.repos.map(\.displayName), ["bar"])
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    func testCancellingTheFolderPickerCreatesNothing() {
        let store = makeStore()
        XCTAssertNil(store.createFromMenu(chooseFolder: { nil }))
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testAddProjectFromMenuAlwaysPromptsEvenWithSessionsOpen() {
        let store = makeStore()
        _ = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let created = store.addProjectFromMenu(chooseFolder: {
            URL(fileURLWithPath: "/work/bar", isDirectory: true)
        })
        XCTAssertEqual(store.repos.map(\.displayName), ["foo", "bar"])
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }
}
