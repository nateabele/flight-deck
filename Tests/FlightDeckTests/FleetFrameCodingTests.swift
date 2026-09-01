import XCTest
@testable import FleetKit

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

    // MARK: The three new replies

    func testTheThreeNewRepliesRoundTrip() throws {
        let hit = TranscriptHit(
            rowID: 1, conversationID: "abc", projectPath: "/proj", conversationName: "n",
            snippet: "s", timestamp: Date(timeIntervalSince1970: 1), offset: 4_096
        )
        let frames: [ServerFrame] = [
            .conversations(cid: 1, WireConversationCatalogue(
                conversations: [WireConversation(id: "abc", name: "n", projectPath: "/proj")],
                sessionActivity: [UUID().uuidString: Date(timeIntervalSince1970: 2)]
            )),
            .searchHits(cid: 2, WireSearchHits(hits: [hit], indexing: nil)),
            .session(cid: 3, UUID()),
        ]
        for frame in frames {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(
                try JSONDecoder().decode(ServerFrame.self, from: data), frame,
                "\(frame) did not survive a round trip"
            )
        }
    }

    /// The reply carrying the indexing progress, since `testTheThreeNewRepliesRoundTrip`
    /// exercises `.searchHits` only with `indexing: nil`.
    func testSearchHitsCarriesIndexingProgress() throws {
        let hit = TranscriptHit(
            rowID: 2, conversationID: "def", projectPath: "/proj", conversationName: "n",
            snippet: "s", timestamp: Date(timeIntervalSince1970: 3), offset: 0
        )
        let frame = ServerFrame.searchHits(cid: 4, WireSearchHits(
            hits: [hit], indexing: WireIndexingProgress(done: 3, total: 10)
        ))
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
    }

    /// `ServerFrame`'s decoder tries its own tags first and treats anything else as a
    /// `FleetEvent` tag — see `TimelineFrameCodingTests.testThePageTagDoesNotCollideWithAnEventTag`
    /// for the property this states for `page`. `conversations`, `hits` and `session` must
    /// keep it too, and are read off an encoded frame rather than spelled as literals here,
    /// for the same reason: `ServerFrame.Tag` is private, so only the raw value that actually
    /// ships can be asserted against.
    func testTheNewFrameTagsDoNotCollideWithEventTags() throws {
        let hit = TranscriptHit(
            rowID: 1, conversationID: "abc", projectPath: "/proj", conversationName: "n",
            snippet: "s", timestamp: Date(timeIntervalSince1970: 1), offset: 0
        )
        let frames: [ServerFrame] = [
            .conversations(cid: 1, WireConversationCatalogue(
                conversations: [], sessionActivity: [:]
            )),
            .searchHits(cid: 2, WireSearchHits(hits: [hit], indexing: nil)),
            .session(cid: 3, UUID()),
        ]
        for frame in frames {
            let tag = try XCTUnwrap(try fields(of: frame)["t"] as? String)
            XCTAssertFalse(tag.contains("."), "\(tag) is shaped like an event tag")
            XCTAssertNil(FleetEventTag(rawValue: tag))
        }
    }

    // MARK: The log fetch, which is the one request that travels Mac → phone

    /// Flattened into the frame, exactly as `ClientFrame.req` flattens its request: one
    /// request reads as one line in a dump, which is what makes a dump usable.
    func testAPhoneRequestEncodesFlatWithItsOwnOp() throws {
        let encoded = try fields(of: ServerFrame.phoneRequest(
            cid: 12, .logs(seconds: 600, limit: 500)
        ))
        XCTAssertEqual(encoded["t"] as? String, "ask")
        XCTAssertEqual(encoded["cid"] as? Int, 12)
        XCTAssertEqual(encoded["op"] as? String, "phone.logs")
        XCTAssertEqual(encoded["seconds"] as? Int, 600)
        XCTAssertEqual(encoded["limit"] as? Int, 500)
    }

    /// The same non-collision property the four replies above keep, for the tag that carries
    /// the only Mac → phone request: `ServerFrame`'s decoder tries its own tags first and
    /// treats anything else as a `FleetEvent` tag.
    func testTheAskTagDoesNotCollideWithAnEventTag() throws {
        let tag = try XCTUnwrap(
            try fields(of: ServerFrame.phoneRequest(cid: 1, .logs(seconds: 1, limit: 1)))["t"]
                as? String
        )
        XCTAssertFalse(tag.contains("."), "\(tag) is shaped like an event tag")
        XCTAssertNil(FleetEventTag(rawValue: tag))
    }

    func testTheLogReplyAndItsRefusalRoundTrip() throws {
        let frames: [ClientFrame] = [
            .logs(cid: 3, WirePhoneLogs(
                entries: [WirePhoneLogEntry(
                    at: "2026-09-01T09:15:00.000+01:00", level: "notice",
                    category: "prompt", message: "prompt derived=toolu_1 shown=toolu_1"
                )],
                truncated: true
            )),
            .logs(cid: 4, WirePhoneLogs(entries: [], truncated: false)),
            .refused(cid: 5, code: "unsupported"),
        ]
        for frame in frames {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(
                try JSONDecoder().decode(ClientFrame.self, from: data), frame,
                "\(frame) did not survive a round trip"
            )
        }
        let ask = ServerFrame.phoneRequest(cid: 6, .logs(seconds: 120, limit: 50))
        let data = try JSONEncoder().encode(ask)
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), ask)
    }

    /// A refusal code is a `String` on this wire, not an enum, so a newer phone inventing one
    /// leaves an older Mac printing "the phone said no" rather than failing to parse the frame
    /// — the same decode-unknown rule `FleetRequestError.server` states for the other
    /// direction.
    func testARefusalCodeThisBuildHasNeverHeardOfStillDecodes() throws {
        let json = Data(#"{"t":"refused","cid":9,"code":"battery_saver"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: json),
            .refused(cid: 9, code: "battery_saver")
        )
    }

    // MARK: What a phone says it can be asked

    /// `caps` is what keeps a new Mac from stranding an old phone: nothing is ever asked of a
    /// peer that did not claim it. Asserted on the bytes for the reason the rest of this file
    /// is — this field is read by a Mac, not by a `Decodable`.
    func testHelloCarriesWhatThePhoneCanBeAsked() throws {
        let encoded = try fields(of: ClientFrame.hello(
            lastSeq: 4, device: "iPhone", caps: [FleetCapability.logs]
        ))
        XCTAssertEqual(encoded["caps"] as? [String], ["logs"])
    }

    /// The compatibility guarantee in the phone → Mac direction, stated as the bytes every
    /// already-paired handset actually sends: a `hello` with no `caps` key must decode as
    /// "claims nothing", not throw. A frame that fails to decode is a connection that never
    /// attaches, so getting this wrong would drop every paired phone off the Mac on upgrade.
    func testAHelloWithoutCapsDecodesAsClaimingNothing() throws {
        let json = Data(#"{"t":"hello","lastSeq":812,"device":"iPhone"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: json),
            .hello(lastSeq: 812, device: "iPhone", caps: [])
        )
    }

    /// And the other half: a client claiming nothing must not put `"caps":[]` on the wire, so
    /// the frame it sends stays byte-identical to the one it sent before this existed.
    func testAHelloThatClaimsNoCapabilitiesOmitsTheKeyEntirely() throws {
        let encoded = try fields(of: ClientFrame.hello(lastSeq: 0, device: nil, caps: []))
        XCTAssertEqual(Set(encoded.keys), ["t", "lastSeq"])
    }
}
