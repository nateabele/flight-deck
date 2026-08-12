import XCTest
@testable import FlightDeck

@MainActor
final class ConversationRepinTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        // Synchronous stand-in for the background transcript read, so tests need no
        // expectations — same rationale as `TranscriptWatcher.drain()` being callable.
        store.titleResolver = { _, done in done(nil) }
        return store
    }

    // `cwd` has no default: every session here is created `in: tmp`, and `applyRegistry`
    // now moves a tab whenever a row's `cwd` disagrees with it, so a fixture-wide stand-in
    // like `"/w"` would silently relocate every tab in this file on its first tick.
    private func row(_ sid: UUID, pid: pid_t = 1, cwd: String,
                     procStart: String = "start-a") -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sid, activity: .busy, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: procStart)
    }

    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    func testResumeMovesThePinButNotTheTabID() {
        let store = makeStore()
        let session = store.newSession(in: tmp)
        let resumed = UUID()

        // Both rows keep `cwd` at `tmp`: this test isolates a repin with no working
        // directory change. `SessionProjectMoveTests` covers the cwd-changes case.
        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])   // anchor
        store.applyRegistry([1: row(resumed, cwd: tmp.path)])                        // /resume

        XCTAssertEqual(store.pinnedConversationID(of: session.id), resumed)
        XCTAssertEqual(store.repos.first?.sessions.first?.id, session.id)
    }

    func testResumeAdoptsTheResumedConversationsTitle() {
        let store = makeStore()
        store.titleResolver = { _, done in done("the resumed conversation") }
        let session = store.newSession(in: tmp)
        let resumed = UUID()

        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])
        store.applyRegistry([1: row(resumed, cwd: tmp.path)])

        XCTAssertEqual(store.title(of: session.id), "the resumed conversation")
    }

    /// An unreadable or nameless transcript leaves the tab called what it was called.
    func testUnresolvableTitleLeavesTheTitleAlone() {
        let store = makeStore()
        let session = store.newSession(in: tmp)
        let before = store.title(of: session.id)

        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])
        store.applyRegistry([1: row(UUID(), cwd: tmp.path)])

        XCTAssertEqual(store.title(of: session.id), before)
    }

    /// The old conversation's outstanding Agent calls will never be answered in the new
    /// transcript, so a stale count would stick forever.
    func testResumeZeroesTheSubagentCount() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])
        store.applySubagentCount(session.id, 3)
        store.applyRegistry([1: row(UUID(), cwd: tmp.path)])

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 0)
    }

    /// The banner refers to a prompt in a conversation the tab has left.
    func testResumeWithdrawsAPendingNotification() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])
        store.applyRegistry([1: row(UUID(), cwd: tmp.path)])

        XCTAssertTrue(spy.withdrawn.contains(session.id))
    }

    func testResumeIsPersisted() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        store.titleResolver = { _, done in done(nil) }
        let session = store.newSession(in: tmp)
        let resumed = UUID()

        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])
        store.applyRegistry([1: row(resumed, cwd: tmp.path)])

        XCTAssertEqual(
            persistence.stored?.sessions.first?.pinnedConversationID, resumed
        )
    }

    /// A steady state must not churn: repinning on every tick would restart the watcher
    /// 120 times a minute.
    func testUnchangedConversationDoesNotRepin() {
        let store = makeStore()
        var resolverCalls = 0
        store.titleResolver = { _, done in resolverCalls += 1; done(nil) }
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])
        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])
        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])

        XCTAssertEqual(resolverCalls, 0)
    }

    /// If the tab closes while `repin`'s title read is still in flight, the late
    /// completion must not resurrect a watcher — nothing would ever stop it again, since
    /// `closeSession` already ran its one-time teardown.
    func testTabClosedDuringTitleResolutionDoesNotGetAWatcher() {
        let store = makeStore()
        var pending: ((String?) -> Void)?
        store.titleResolver = { _, done in pending = done }
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: row(session.pinnedConversationID, cwd: tmp.path)])   // anchor
        store.applyRegistry([1: row(UUID(), cwd: tmp.path)])                        // /resume, resolver now pending
        store.closeSession(session.id)
        pending?("a title that arrives too late")

        XCTAssertFalse(store.watchedSessionIDs.contains(session.id))
        XCTAssertNil(store.status(for: session.id))
        XCTAssertNil(store.title(of: session.id))
        XCTAssertNil(store.pinnedConversationID(of: session.id))
    }

    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    final class SpyNotifier: Notifying {
        var withdrawn: [UUID] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, body: String) {}
        func withdraw(sessionID: UUID) { withdrawn.append(sessionID) }
    }
}
