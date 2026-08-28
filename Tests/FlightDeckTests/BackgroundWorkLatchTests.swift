import XCTest
@testable import FlightDeck

/// Whether a tab has a background task running under its agent — latched, because upstream
/// (`ClaudeStatusFile.Entry.reportsBackgroundWork`) can only report the fact while the
/// session is idle.
@MainActor
final class BackgroundWorkLatchTests: XCTestCase {
    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    /// One registry row. `reportsBackgroundWork` is what `"shell"` decodes to (Task 1).
    private func row(
        _ conversation: UUID, _ activity: SessionActivity, background: Bool = false
    ) -> [pid_t: ClaudeStatusFile.Entry] {
        [1: .init(pid: 1, sessionID: conversation, activity: activity, waitingFor: nil,
                  startedAt: 1, cwd: tmp.path, procStart: "start-a",
                  reportsBackgroundWork: background)]
    }

    private func makeStore() -> (SessionStore, Session) {
        let store = SessionStore(provider: nil, persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        return (store, store.newSession(in: tmp))
    }

    /// `shell` sets it; a later plain `idle` is the only thing that clears it.
    func testShellSetsAndIdleClears() {
        let (store, session) = makeStore()
        let cid = session.pinnedConversationID

        store.applyRegistry(row(cid, .idle, background: true))
        XCTAssertTrue(store.backgroundWorkSessions.contains(session.id))

        store.applyRegistry(row(cid, .idle))
        XCTAssertFalse(store.backgroundWorkSessions.contains(session.id))
    }

    /// The whole reason for the latch: upstream stops reporting the fact during a turn, so a
    /// `busy` tick must not read as "the dev server stopped".
    func testBusyCarriesTheFactForward() {
        let (store, session) = makeStore()
        let cid = session.pinnedConversationID

        store.applyRegistry(row(cid, .idle, background: true))
        store.applyRegistry(row(cid, .busy))
        XCTAssertTrue(store.backgroundWorkSessions.contains(session.id))

        store.applyRegistry(row(cid, .waiting))
        XCTAssertTrue(store.backgroundWorkSessions.contains(session.id))

        store.applyRegistry(row(cid, .idle))
        XCTAssertFalse(store.backgroundWorkSessions.contains(session.id))
    }

    /// An agent that exits takes its children with it.
    func testEmptyRegistryClears() {
        let (store, session) = makeStore()
        store.applyRegistry(row(session.pinnedConversationID, .idle, background: true))
        store.applyRegistry([:])
        XCTAssertFalse(store.backgroundWorkSessions.contains(session.id))
    }
}
