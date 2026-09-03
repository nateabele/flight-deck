import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class FleetProjectionTests: XCTestCase {
    private func store() -> SessionStore {
        SessionStore(provider: nil, persistence: nil)
    }

    func testTheProjectionCarriesEveryProjectAndSessionInOrder() {
        let store = store()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/beta"))
        let snapshot = FleetProjection.snapshot(of: store)
        XCTAssertEqual(snapshot.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(snapshot.projects[0].sessions.map(\.id), [a.id])
        XCTAssertEqual(snapshot.projects[1].sessions.map(\.id), [b.id])
    }

    /// A tab with no registered agent process is statusless, and that has to reach the wire
    /// as `nil` rather than as `"idle"` — see `WireSession.activity`.
    func testASessionWithNoRegisteredProcessProjectsANilActivity() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        XCTAssertNil(FleetProjection.snapshot(of: store).projects[0].sessions[0].activity)
    }

    func testStatusAndUnreadAreCarriedOntoTheSession() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.applyRegistryForTesting([
            session.id: SessionStatus(
                activity: .waiting, waitingFor: "permission prompt", subagentCount: 2
            )
        ])
        store.markUnreadForTesting([session.id])
        let projected = FleetProjection.snapshot(of: store).projects[0].sessions[0]
        XCTAssertEqual(projected.activity, "waiting")
        XCTAssertEqual(projected.waitingFor, "permission prompt")
        XCTAssertEqual(projected.subagentCount, 2)
        XCTAssertTrue(projected.isUnread)
    }

    func testCollapseStateIsCarried() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let project = try! XCTUnwrap(store.repos.first)
        store.setCollapsed(true, forProjectAt: project.id)
        XCTAssertTrue(FleetProjection.snapshot(of: store).projects[0].isCollapsed)
    }

    func testTheAgentIsCarriedAsItsRawValue() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        XCTAssertEqual(
            FleetProjection.snapshot(of: store).projects[0].sessions[0].agent,
            AgentID.claude.rawValue
        )
    }

    func testProjectingAnEmptyStoreIsAnEmptySnapshotNotACrash() {
        XCTAssertEqual(FleetProjection.snapshot(of: store()), .empty)
    }

    /// `allowsBlockedAbort` is a fact about the Mac, not any one session, but it rides on
    /// every `WireSession` because that is the only shape a client reads. Read off the
    /// store's own `preferences`, the same way `planGates` is — see the doc comment on
    /// `FleetProjection.snapshot(of:planGates:)`.
    func testTheProjectionCarriesThePreference() {
        let preferences = PreferencesStore(persistence: nil)
        preferences.allowsBlockedPromptAbort = true
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let snapshot = FleetProjection.snapshot(of: store)
        XCTAssertTrue(snapshot.projects.flatMap(\.sessions).allSatisfy(\.allowsBlockedAbort))
    }

    /// The default: a store built with no preferences configured must not turn the switch on
    /// by accident — off is the safe direction for a control that drives a terminal.
    func testTheProjectionDefaultsThePreferenceToOff() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let snapshot = FleetProjection.snapshot(of: store)
        XCTAssertFalse(snapshot.projects.flatMap(\.sessions).contains { $0.allowsBlockedAbort })
    }
}
