import XCTest
import FleetKit

final class FleetWireTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testASnapshotSurvivesAnEncodeDecodeRoundTrip() throws {
        let snapshot = FleetSnapshot(projects: [
            WireProject(
                id: UUID(), name: "flight-deck", path: "/w/flight-deck", isCollapsed: false,
                sessions: [
                    WireSession(
                        id: UUID(), title: "mobile", agent: "claude",
                        activity: "busy", waitingFor: nil, subagentCount: 2, isUnread: false
                    )
                ]
            )
        ])
        XCTAssertEqual(try roundTrip(snapshot), snapshot)
    }

    /// A session with no agent process is NOT idle — it is statusless, and the two render
    /// differently (nothing versus a dot). `nil` has to survive the wire or every dead tab
    /// on the phone looks alive.
    func testAStatuslessSessionStaysStatuslessAcrossTheWire() throws {
        let session = WireSession(
            id: UUID(), title: "dormant", agent: "codex",
            activity: nil, waitingFor: nil, subagentCount: 0, isUnread: true
        )
        XCTAssertNil(try roundTrip(session).activity)
    }

    /// The Mac may be running a newer Flight Deck than the phone. An agent the client has
    /// never heard of must arrive as an unrenderable-but-present string rather than
    /// throwing and taking the whole snapshot down with it — which is what a client-side
    /// `AgentID` enum would have done.
    func testAnUnknownAgentDecodesRatherThanThrowing() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","title":"t","agent":"gemini",
         "subagentCount":0,"isUnread":false}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WireSession.self, from: json).agent, "gemini")
    }

    /// An older Mac sends no such key. The phone must decode that as `false`, not throw — a
    /// throw here takes the entire snapshot down, not one field.
    func testWireSessionDecodesWithoutBackgroundWorkKey() throws {
        let json = """
        {"id":"A4C9067B-9CAF-43CB-8B75-88A145249058","title":"frontend-state",
         "agent":"claude","activity":"idle","subagentCount":0,"isUnread":false}
        """.data(using: .utf8)!
        let session = try JSONDecoder().decode(WireSession.self, from: json)
        XCTAssertFalse(session.hasBackgroundWork)
    }

    func testActivityChangedRoundTripsBackgroundWork() throws {
        let event = FleetEvent.activityChanged(
            id: UUID(), activity: "idle", waitingFor: nil,
            subagentCount: 0, hasBackgroundWork: true
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(FleetEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }
}
