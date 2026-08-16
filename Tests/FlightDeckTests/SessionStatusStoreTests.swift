import XCTest
@testable import FlightDeck

@MainActor
final class SessionStatusStoreTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        // Synchronous stand-in for the background transcript read: the rows below can
        // change conversation under a stable pid, which repins, and the real resolver
        // would put a `Task.detached` file read behind a status assertion.
        store.titleResolver = { _, done in done(nil) }
        return store
    }

    // `cwd` has no default, for the reason `ConversationRepinTests` gave when it dropped
    // its own: every session here lives in `tmp`, and `applyRegistry` retargets a tab's
    // transcript whenever a row's `cwd` disagrees with it, so a fixture-wide stand-in like
    // `"/w"` would restart a watcher on a made-up path underneath every status assertion in
    // this file.
    private func entry(_ sid: UUID, _ activity: SessionActivity,
                       waitingFor: String? = nil, pid: pid_t = 1,
                       cwd: String, procStart: String = "start-a")
        -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sid, activity: activity, waitingFor: waitingFor,
              startedAt: 1, cwd: cwd, procStart: procStart)
    }

    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    func testRegistryPopulatesStatusForKnownSession() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])

        XCTAssertEqual(store.status(for: session.id)?.activity, .busy)
    }

    /// The registry lists every `claude` on the machine, including ones the user runs
    /// in other terminals. Those must never appear.
    func testIgnoresSessionsNotInStore() {
        let store = makeStore()
        let stranger = UUID()

        store.applyRegistry([1: entry(stranger, .busy, cwd: tmp.path)])

        XCTAssertNil(store.status(for: stranger))
        XCTAssertTrue(store.statuses.isEmpty)
    }

    func testSubagentCountSurvivesRegistryRefresh() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])
        store.applySubagentCount(session.id, 3)
        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 3)
    }

    /// A count can arrive before the registry has ever been read.
    func testSubagentCountArrivingBeforeRegistryIsRetained() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applySubagentCount(session.id, 2)
        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 2)
    }

    func testDisappearingSessionClearsStatus() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])
        store.applyRegistry([:])

        XCTAssertNil(store.status(for: session.id))
    }

    /// Two live `claude` processes on one conversation are both real. The old
    /// dedupe-by-sessionId in the watcher would have hidden one of them.
    func testTwoProcessesOnOneConversationBothSurviveTheJoin() {
        let store = makeStore()
        let first = store.newSession(in: tmp)
        let second = store.newSession(in: tmp)

        store.applyRegistry([
            1: entry(first.pinnedConversationID, .busy, pid: 1, cwd: tmp.path),
            2: entry(second.pinnedConversationID, .waiting, pid: 2, cwd: tmp.path,
                     procStart: "start-b"),
        ])

        XCTAssertEqual(store.status(for: first.id)?.activity, .busy)
        XCTAssertEqual(store.status(for: second.id)?.activity, .waiting)
    }

    /// Once anchored, the tab follows its pid. The conversation id in the row is no longer
    /// consulted for the status join, which is what lets a resume keep the icon alive.
    func testStatusSurvivesTheConversationChangingUnderTheSamePid() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([
            1: entry(session.pinnedConversationID, .busy, pid: 1, cwd: tmp.path),
        ])
        store.applyRegistry([1: entry(UUID(), .waiting, pid: 1, cwd: tmp.path)])

        XCTAssertEqual(store.status(for: session.id)?.activity, .waiting)
    }

    /// Also covers withdrawal: closing a waiting session is the "prompt that will never
    /// resolve" case that `applyRegistry` cannot observe on its own, since both its
    /// before/after snapshots already lack the closed id.
    func testClosingSessionDropsItsStatus() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        let session = store.newSession(in: tmp)

        store.applyRegistry([
            1: entry(session.id, .waiting, waitingFor: "permission prompt", cwd: tmp.path),
        ])
        store.applySubagentCount(session.id, 2)
        store.closeSession(session.id)

        XCTAssertNil(store.status(for: session.id))
        // subagentCounts has no public reader; the only externally observable proof it
        // was cleared is that a restart under the same UUID starts back at 0 rather than
        // inheriting 2 — this is exactly what testDisappearingSessionAlsoClearsItsSubagentCount
        // covers for the registry-disappearance path, so here we assert what we can reach
        // directly: the withdrawal.
        XCTAssertEqual(spy.withdrawn, [session.id])
    }

    func testWaitingReasonIsCarriedThrough() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([
            1: entry(session.id, .waiting, waitingFor: "input needed", cwd: tmp.path),
        ])

        XCTAssertEqual(store.status(for: session.id)?.waitingFor, "input needed")
    }

    /// A pane can outlive its `claude`. When a new process reuses the same session
    /// UUID, it must not inherit the dead one's sub-agent count.
    func testDisappearingSessionAlsoClearsItsSubagentCount() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])
        store.applySubagentCount(session.id, 3)
        store.applyRegistry([:])                                     // claude exited
        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])  // restarted, same UUID

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 0)
    }

    private final class SpyNotifier: Notifying {
        var notified: [(UUID, String, String)] = []
        var withdrawn: [UUID] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, body: String) {
            notified.append((sessionID, title, body))
        }
        func withdraw(sessionID: UUID) { withdrawn.append(sessionID) }
    }

    func testNotifiesWhenSessionStartsWaitingAndAppIsBackgrounded() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        store.appIsActive = { false }
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])
        store.applyRegistry([
            1: entry(session.id, .waiting, waitingFor: "permission prompt", cwd: tmp.path),
        ])

        XCTAssertEqual(spy.notified.count, 1)
        XCTAssertEqual(spy.notified.first?.0, session.id)
        XCTAssertEqual(spy.notified.first?.2, "Waiting for you — permission prompt")
    }

    func testDoesNotNotifyWhileAppIsFrontmost() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        store.appIsActive = { true }
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: entry(session.id, .waiting, cwd: tmp.path)])

        XCTAssertTrue(spy.notified.isEmpty)
    }

    func testWithdrawsWhenPromptResolves() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        store.appIsActive = { false }
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: entry(session.id, .waiting, cwd: tmp.path)])
        store.applyRegistry([1: entry(session.id, .busy, cwd: tmp.path)])

        XCTAssertEqual(spy.withdrawn, [session.id])
    }

    func testActivationNotificationSelectsSession() {
        let store = makeStore()
        let first = store.newSession(in: tmp)
        let second = store.newSession(in: tmp)
        store.selectSession(first.id)

        NotificationCenter.default.post(
            name: .flightDeckActivateSession,
            object: nil,
            userInfo: ["sessionID": second.id]
        )

        // The observer is registered with `queue: .main`, so the block is ENQUEUED
        // rather than run synchronously on the posting thread. Pump the run loop until
        // it lands instead of assuming it already has -- asserting immediately passes
        // only by incidental scheduling.
        let deadline = Date().addingTimeInterval(2)
        while store.selectedSessionID != second.id, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(store.selectedSessionID, second.id)
    }
}
