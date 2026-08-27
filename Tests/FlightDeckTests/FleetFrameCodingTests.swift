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
            id: UUID(), activity: "waiting", waitingFor: "permission prompt", subagentCount: 3,
            hasBackgroundWork: true
        ))
        XCTAssertEqual(encoded["t"] as? String, "session.activity")
        XCTAssertEqual(encoded["activity"] as? String, "waiting")
        XCTAssertEqual(encoded["waitingFor"] as? String, "permission prompt")
        XCTAssertEqual(encoded["subagentCount"] as? Int, 3)
        // Asserted by literal key name, like every other field here: an in-repo rename of
        // the `CodingKeys` case would stay green on a round trip alone and only break a
        // separately-built client, which is exactly what this file exists to catch.
        XCTAssertEqual(encoded["hasBackgroundWork"] as? Bool, true)
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
            .activityChanged(id: UUID(), activity: nil, waitingFor: nil, subagentCount: 0,
                             hasBackgroundWork: true),
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

    /// The Mac cannot name a paired phone from anything the handshake tells it, so `hello`
    /// is the only place a device can say what it is. Asserted on the bytes for the same
    /// reason the rest of this file is: this field is read by a Mac, not by a `Decodable`.
    func testHelloCarriesTheNameTheDeviceCallsItself() throws {
        let encoded = try fields(of: ClientFrame.hello(lastSeq: 4, device: "Nate's iPhone"))
        XCTAssertEqual(encoded["t"] as? String, "hello")
        XCTAssertEqual(encoded["lastSeq"] as? Int, 4)
        XCTAssertEqual(encoded["device"] as? String, "Nate's iPhone")
    }

    /// The compatibility guarantee, stated as bytes an older phone actually sends: a `hello`
    /// with no `device` key must decode, not throw. Getting this wrong would not degrade the
    /// device list — it would drop every already-paired phone off the Mac on upgrade, since
    /// a frame that fails to decode is a connection that never attaches.
    func testAHelloWithoutADeviceNameStillDecodes() throws {
        let json = Data(#"{"t":"hello","lastSeq":812}"#.utf8)
        let frame = try JSONDecoder().decode(ClientFrame.self, from: json)
        XCTAssertEqual(frame, .hello(lastSeq: 812, device: nil))
    }

    /// And the other half of that: a client claiming nothing must not put `"device":null` on
    /// the wire, so the frame an upgraded phone sends is byte-identical to the old one.
    func testAHelloThatClaimsNoNameOmitsTheKeyEntirely() throws {
        let encoded = try fields(of: ClientFrame.hello(lastSeq: 0, device: nil))
        XCTAssertEqual(Set(encoded.keys), ["t", "lastSeq"])
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
            .hello(lastSeq: 0, device: nil), .hello(lastSeq: 812, device: "iPhone"),
            .cmd(cid: 1, .markRead(id: UUID())), .cmd(cid: 2, .markUnread(id: UUID()))
        ]
        for frame in client {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), frame)
        }
    }
}
