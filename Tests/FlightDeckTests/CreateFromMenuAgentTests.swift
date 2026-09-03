import XCTest
@testable import FlightDeck

/// Coverage for `SessionStore.createFromMenu(agent:chooseFolder:)` — the async overload every
/// New Session action (menu items and the sidebar button, Task 12) now goes through instead of
/// the plain synchronous `createFromMenu()`. Mirrors `SessionCreationTests`' scenario categories
/// for that sibling method (active session, last-active project, first repo, prompt path), at
/// minimum for the `.claude` branch: that is the one with a behaviour-preservation guarantee
/// ("claude's behaviour must not change"), and for `.claude` the method never actually suspends
/// — `createSession(agent:in:)` special-cases `agent == .claude` to call the synchronous
/// `newSession` directly — so these tests can `await` it without any risk of touching a real
/// codex process.
@MainActor
final class CreateFromMenuAgentTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    // Same reason as `SessionCreationTests`: `SessionStore.provider` is `weak`, so an
    // unretained `StubProvider` would deallocate immediately.
    private var retainedProviders: [StubProvider] = []

    private func makeStore() -> SessionStore {
        let provider = StubProvider()
        retainedProviders.append(provider)
        return SessionStore(provider: provider)
    }

    private func titles(_ store: SessionStore) -> [String] {
        store.repos.flatMap(\.sessions).map(\.title)
    }

    /// Mirrors `testCreateFromMenuAddsBelowActiveWhenSessionsExist`.
    func testCreateFromMenuAgentAddsBelowActiveWhenSessionsExist() async {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        _ = store.newSession(in: url)
        var prompted = false
        let created = await store.createFromMenu(
            agent: .claude, chooseFolder: { prompted = true; return nil }
        )

        XCTAssertFalse(prompted, "⌘N must not prompt for a folder when a session is active")
        XCTAssertEqual(store.repos[0].sessions.count, 2)
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    /// Mirrors `testCreateFromMenuWithReposButNoSelectionStillCreatesASession`: with the
    /// selection cleared, the last-active project — not a prompt — is where ⌘N lands.
    func testCreateFromMenuAgentWithReposButNoSelectionStillCreatesASession() async throws {
        let store = makeStore()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = store.newSession(in: root)
        store.selectedSessionID = nil

        var prompted = false
        let created = await store.createFromMenu(
            agent: .claude, chooseFolder: { prompted = true; return nil }
        )

        XCTAssertNotNil(created, "⌘N silently did nothing with a cleared selection")
        XCTAssertFalse(prompted, "there is a project to create in; no folder prompt is needed")
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    /// Mirrors `testOnlyAnEmptyProjectStillCreatesWithoutPrompting`: the remembered project
    /// survives its last session leaving, so ⌘N still lands there rather than prompting.
    func testCreateFromMenuAgentTargetsTheLastActiveProjectEvenWhenItIsEmpty() async {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, _, done in done(nil) }
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        store.closeSession(a.id)
        store.selectedSessionID = nil

        let created = await store.createFromMenu(
            agent: .claude, chooseFolder: { XCTFail("must not prompt"); return nil }
        )

        XCTAssertEqual(created?.workingDirectory, "/a")
    }

    /// The first-repo fallback: `lastActiveProjectURL` is only ever set by
    /// `selectedSessionID`'s `didSet` locating a real session, so the only way to reach this
    /// branch through the store's own public seams — without ever having selected a session —
    /// is restoring a snapshot that records a project but seeds no session, exactly as
    /// `ProjectPersistenceTests.testAProjectsOnlySnapshotRestoresTheProjectAndSeedsNoSession`
    /// does for the plain `createFromMenu()`.
    func testCreateFromMenuAgentFallsBackToTheFirstRepoWithNoLastActiveProject() async {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [],
            projects: [.init(path: "/w/a", isCollapsed: false)],
            sessionCounter: 0
        )
        let store = SessionStore(provider: nil, persistence: persistence)
        store.titleResolver = { _, _, done in done(nil) }
        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        XCTAssertNil(store.lastActiveProjectURL, "no session was ever selected yet")

        let created = await store.createFromMenu(
            agent: .claude, chooseFolder: { XCTFail("must not prompt"); return nil }
        )

        XCTAssertEqual(created?.workingDirectory, "/w/a")
    }

    /// Mirrors `testCreateFromMenuPromptsAndAddsProjectWhenEmpty`: the reroute to Add Project
    /// when nothing is open at all.
    func testCreateFromMenuAgentPromptsAndAddsProjectWhenEmpty() async {
        let store = makeStore()
        var prompted = false
        let created = await store.createFromMenu(agent: .claude, chooseFolder: {
            prompted = true
            return URL(fileURLWithPath: "/work/bar", isDirectory: true)
        })

        XCTAssertTrue(prompted)
        XCTAssertEqual(store.repos.map(\.displayName), ["bar"])
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    /// Mirrors `testCancellingTheFolderPickerCreatesNothing`.
    func testCancellingTheFolderPickerCreatesNothingForTheAgentOverload() async {
        let store = makeStore()
        let created = await store.createFromMenu(agent: .claude, chooseFolder: { nil })
        XCTAssertNil(created)
        XCTAssertTrue(store.repos.isEmpty)
    }
}
