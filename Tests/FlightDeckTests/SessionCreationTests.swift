import XCTest
@testable import FlightDeck

@MainActor
final class SessionCreationTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    // `SessionStore.provider` is `weak`; a `StubProvider` that isn't held anywhere else
    // deallocates immediately and `makeSurface`/`tick` silently never run. Retain one per
    // test here so the provider stays alive for the store's lifetime.
    private var retainedProviders: [StubProvider] = []

    private func makeStore() -> SessionStore {
        let provider = StubProvider()
        retainedProviders.append(provider)
        return SessionStore(provider: provider)
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

    /// Clicking below the last row clears the List's selection while repos remain.
    /// ⌘N must still create something rather than silently doing nothing.
    func testCreateFromMenuWithReposButNoSelectionStillCreatesASession() throws {
        let store = makeStore()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = store.newSession(in: root)
        store.selectedSessionID = nil

        var prompted = false
        let created = store.createFromMenu(chooseFolder: { prompted = true; return nil })

        XCTAssertNotNil(created, "⌘N silently did nothing with a cleared selection")
        XCTAssertFalse(prompted, "there is a project to create in; no folder prompt is needed")
        XCTAssertEqual(store.selectedSessionID, created?.id)
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

    /// `projectDirectory(for:)` resolves against the real filesystem (see
    /// `SessionCreationHelperTests`), so the dropped URLs must be real directories, not the
    /// literal `/work/foo`-style paths used elsewhere in this file for sessions created directly.
    func testDroppingTwoFoldersCreatesAProjectEachAndActivatesTheLast() throws {
        let store = makeStore()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let foo = root.appendingPathComponent("foo", isDirectory: true)
        let bar = root.appendingPathComponent("bar", isDirectory: true)
        try FileManager.default.createDirectory(at: foo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let created = store.acceptDroppedURLs([foo, bar])

        XCTAssertEqual(store.repos.map(\.displayName), ["foo", "bar"])
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 2)
        XCTAssertEqual(store.selectedSessionID, created?.id)
        XCTAssertEqual(store.repos[1].sessions.last?.id, created?.id)
    }

    /// Dropping a folder that is already a project adds another session to it.
    func testDroppingAKnownFolderAddsASessionToThatProject() throws {
        let store = makeStore()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("foo", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = store.newSession(in: url)
        let created = store.acceptDroppedURLs([url])

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    func testDroppingNothingCreatesNothing() {
        let store = makeStore()
        XCTAssertNil(store.acceptDroppedURLs([]))
        XCTAssertTrue(store.repos.isEmpty)
    }

    /// The case the empty-project state creates: the remembered project has to survive its
    /// last session leaving, or ⌘N lands somewhere arbitrary.
    @MainActor
    func testNewSessionTargetsTheLastActiveProjectEvenWhenItIsEmpty() {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, done in done(nil) }
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/b", isDirectory: true))
        // /a is now an empty project, /b holds the session and is last-active.
        store.selectedSessionID = nil

        let created = store.createFromMenu(chooseFolder: { XCTFail("must not prompt"); return nil })

        XCTAssertEqual(created?.workingDirectory, "/b")
    }

    @MainActor
    func testLastActiveProjectFollowsAMovedSelectedSession() {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, done in done(nil) }
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/moved", isDirectory: true))

        XCTAssertEqual(store.lastActiveProjectURL?.path, "/moved")
    }

    @MainActor
    func testNilSelectionDoesNotForgetTheLastActiveProject() {
        let store = SessionStore(provider: nil, persistence: nil)
        _ = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.selectedSessionID = nil

        XCTAssertEqual(store.lastActiveProjectURL?.path, "/a")
    }

    /// A sidebar holding only an empty project still offers New Session, not Add Project:
    /// an empty project is somewhere to put a session.
    @MainActor
    func testOnlyAnEmptyProjectStillCreatesWithoutPrompting() {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, done in done(nil) }
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/b", isDirectory: true))
        store.closeSession(a.id)
        // /a survives as an empty project; /b was pruned by closeSession.
        store.selectedSessionID = nil

        let created = store.createFromMenu(chooseFolder: { XCTFail("must not prompt"); return nil })

        XCTAssertNotNil(created)
    }
}
