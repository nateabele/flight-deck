import XCTest
@testable import FlightDeck

@MainActor
final class SessionStatusStoreTests: XCTestCase {
    private func makeStore() -> SessionStore {
        SessionStore(provider: nil, persistence: nil)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity,
                       waitingFor: String? = nil) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity,
              waitingFor: waitingFor, startedAt: 1)
    }

    func testRegistryPopulatesStatusForKnownSession() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])

        XCTAssertEqual(store.status(for: session.id)?.activity, .busy)
    }

    /// The registry lists every `claude` on the machine, including ones the user runs
    /// in other terminals. Those must never appear.
    func testIgnoresSessionsNotInStore() {
        let store = makeStore()
        let stranger = UUID()

        store.applyRegistry([stranger: entry(stranger, .busy)])

        XCTAssertNil(store.status(for: stranger))
        XCTAssertTrue(store.statuses.isEmpty)
    }

    func testSubagentCountSurvivesRegistryRefresh() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])
        store.applySubagentCount(session.id, 3)
        store.applyRegistry([session.id: entry(session.id, .busy)])

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 3)
    }

    /// A count can arrive before the registry has ever been read.
    func testSubagentCountArrivingBeforeRegistryIsRetained() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applySubagentCount(session.id, 2)
        store.applyRegistry([session.id: entry(session.id, .busy)])

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 2)
    }

    func testDisappearingSessionClearsStatus() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])
        store.applyRegistry([:])

        XCTAssertNil(store.status(for: session.id))
    }

    func testClosingSessionDropsItsStatus() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])
        store.applySubagentCount(session.id, 2)
        store.closeSession(session.id)

        XCTAssertNil(store.status(for: session.id))
    }

    func testWaitingReasonIsCarriedThrough() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([
            session.id: entry(session.id, .waiting, waitingFor: "input needed"),
        ])

        XCTAssertEqual(store.status(for: session.id)?.waitingFor, "input needed")
    }
}
