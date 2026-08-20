import XCTest
import FleetKit

/// These tests assert the *bytes*, not just round-tripping. Round-tripping alone would pass
/// happily against Swift's synthesized nesting, which is exactly the shape the spec does not
/// describe — and the first time anyone reads a packet dump is the first time they would
/// find out.
final class FleetFrameCodingTests: XCTestCase {
    private func fields<T: Encodable>(of value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Events carry a flat discriminator

    func testARenameEncodesFlatWithItsTypeTag() throws {
        let id = UUID()
        let encoded = try fields(of: FleetEvent.renamed(id: id, title: "two", origin: .agent))
        XCTAssertEqual(encoded["t"] as? String, "session.renamed")
        XCTAssertEqual(encoded["id"] as? String, id.uuidString)
        XCTAssertEqual(encoded["title"] as? String, "two")
        XCTAssertEqual(encoded["origin"] as? String, "agent")
    }

    func testAnActivityChangeEncodesItsWholeTriple() throws {
        let encoded = try fields(of: FleetEvent.activityChanged(
            id: UUID(), activity: "waiting", waitingFor: "permission prompt", subagentCount: 3
        ))
        XCTAssertEqual(encoded["t"] as? String, "session.activity")
        XCTAssertEqual(encoded["activity"] as? String, "waiting")
        XCTAssertEqual(encoded["waitingFor"] as? String, "permission prompt")
        XCTAssertEqual(encoded["subagentCount"] as? Int, 3)
    }

    func testEveryEventCaseRoundTrips() throws {
        let project = WireProject(id: UUID(), name: "n", path: "/w/n")
        let session = WireSession(id: UUID(), title: "s", agent: "codex")
        let cases: [FleetEvent] = [
            .projectAdded(project, at: 1),
            .projectRemoved(id: UUID()),
            .projectCollapsed(id: UUID(), isCollapsed: true),
            .projectsReordered(order: [UUID(), UUID()]),
            .sessionAdded(session, project: project.id, at: 0),
            .sessionRemoved(id: UUID()),
            .sessionMoved(id: UUID(), project: project.id, at: 2),
            .sessionsReordered(project: project.id, order: [UUID()]),
            .renamed(id: UUID(), title: "t", origin: .user),
            .activityChanged(id: UUID(), activity: nil, waitingFor: nil, subagentCount: 0),
            .unreadChanged(id: UUID(), isUnread: true)
        ]
        for event in cases {
            let data = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event,
                           "\(event) did not survive a round trip")
        }
    }

    /// An unrecognised `t` must throw rather than decode to some default. A frame the client
    /// silently misreads is worse than one it refuses: the first leaves a wrong fleet on
    /// screen, the second is a log line.
    func testAnUnknownEventTypeThrows() {
        let json = Data(#"{"t":"session.teleported","id":"x"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FleetEvent.self, from: json))
    }

    // MARK: Frames

    func testAnEventFrameCarriesItsSequenceBesideTheEventsOwnFields() throws {
        let id = UUID()
        let encoded = try fields(of: ServerFrame.event(
            seq: 813, .renamed(id: id, title: "x", origin: .user)
        ))
        XCTAssertEqual(encoded["seq"] as? Int, 813)
        XCTAssertEqual(encoded["t"] as? String, "session.renamed")
        XCTAssertEqual(encoded["title"] as? String, "x")
        XCTAssertNil(encoded["event"], "the event must be flat in the frame, not nested")
    }

    func testASnapshotFrameNamesWhyItWasSent() throws {
        let encoded = try fields(of: ServerFrame.snapshot(
            seq: 9, fleet: .empty, reason: .seqTooOld
        ))
        XCTAssertEqual(encoded["t"] as? String, "snapshot")
        XCTAssertEqual(encoded["reason"] as? String, "seqTooOld")
        XCTAssertNotNil(encoded["fleet"])
    }

    func testCommandFramesCarryTheirCorrelationIDAndOperation() throws {
        let id = UUID()
        let encoded = try fields(of: ClientFrame.cmd(cid: 41, .markRead(id: id)))
        XCTAssertEqual(encoded["t"] as? String, "cmd")
        XCTAssertEqual(encoded["cid"] as? Int, 41)
        XCTAssertEqual(encoded["op"] as? String, "session.markRead")
        XCTAssertEqual(encoded["id"] as? String, id.uuidString)
    }

    func testEveryFrameRoundTrips() throws {
        let server: [ServerFrame] = [
            .snapshot(seq: 1, fleet: .empty, reason: .initial),
            .event(seq: 2, .sessionRemoved(id: UUID())),
            .ack(cid: 7),
            .err(cid: 8, code: "unknown_session")
        ]
        for frame in server {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
        }
        let client: [ClientFrame] = [
            .hello(lastSeq: 0), .hello(lastSeq: 812),
            .cmd(cid: 1, .markRead(id: UUID())), .cmd(cid: 2, .markUnread(id: UUID()))
        ]
        for frame in client {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), frame)
        }
    }
}
