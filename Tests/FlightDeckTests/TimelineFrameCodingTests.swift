import XCTest
@testable import FleetKit

/// The history channel's frames, and the two properties of them that are not obvious.
///
/// One: `req` and `cmd` share a socket and a `cid` space but are different verbs. `ack` means
/// *dispatched, not done* (spec §4) — correct for "mark this read", and wrong for "tell me
/// what is in this session", which has to answer with data. So a request gets its own tag and
/// its own reply frame rather than being smuggled into `FleetCommand`.
///
/// Two: `page` carries a `cid` and no `seq`. A history fetch is not fleet state and must not
/// move a client's resume point — see `testAPageCarriesNoSequence`.
///
/// Every field of every hand-written codec here is round-tripped at a **distinct, non-default**
/// value, and the wire keys are asserted separately from the round trip. Neither check alone is
/// enough: a round trip cannot see a `CodingKey` swapped symmetrically in both directions, and
/// a key assertion on a default-valued object cannot see a field the encoder dropped.
final class TimelineFrameCodingTests: XCTestCase {
    private let session = UUID(uuidString: "6C6E9A1E-6E5E-4F5A-9C7C-0F1A2B3C4D5E")!
    private let otherSession = UUID(uuidString: "1B2C3D4E-5F60-4712-8A9B-0C1D2E3F4A5B")!

    private func roundTrip(_ frame: ClientFrame) throws -> ClientFrame {
        try JSONDecoder().decode(ClientFrame.self, from: JSONEncoder().encode(frame))
    }

    private func roundTrip(_ frame: ServerFrame) throws -> ServerFrame {
        try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(frame))
    }

    private func fields<T: Encodable>(of value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: The request

    func testEveryAnchorRoundTrips() throws {
        for anchor in [TimelineAnchor.latest, .before(4096), .after(0)] {
            let frame = ClientFrame.req(
                cid: 7, .timeline(session: session, anchor: anchor, limit: 40)
            )
            XCTAssertEqual(try roundTrip(frame), frame, "\(anchor) did not survive")
        }
    }

    /// Every field of the request at a distinct, non-default value, so a decoder reading one
    /// field out of another's key is visible. `limit` is deliberately not
    /// `TimelineLimits.defaultLimit` and differs from both `cid` and the cursor.
    func testARequestRoundTripsEveryFieldAtADistinctValue() throws {
        let frame = ClientFrame.req(
            cid: 9_001, .timeline(session: session, anchor: .before(524_291), limit: 137)
        )
        guard case .req(let cid, let request) = try roundTrip(frame) else {
            return XCTFail("a req did not decode as a req")
        }
        XCTAssertEqual(cid, 9_001)
        guard case .timeline(let decodedSession, let anchor, let limit) = request else {
            return XCTFail("the request did not decode as a timeline request")
        }
        XCTAssertEqual(decodedSession, session)
        XCTAssertEqual(anchor, .before(524_291))
        XCTAssertEqual(limit, 137)
    }

    /// The request is flattened into the frame object, the same way `cmd` flattens a
    /// `FleetCommand`, so one request reads as one line in a packet dump.
    func testARequestIsOneFlatObject() throws {
        let json = try fields(
            of: ClientFrame.req(
                cid: 7, .timeline(session: session, anchor: .before(88), limit: 40)
            )
        )
        XCTAssertEqual(json["t"] as? String, "req")
        XCTAssertEqual(json["cid"] as? Int, 7)
        XCTAssertEqual(json["op"] as? String, "timeline.page")
        XCTAssertEqual(json["anchor"] as? String, "before")
        XCTAssertEqual(json["cursor"] as? Int, 88)
        XCTAssertNil(json["request"], "the request must not be nested under a key")
    }

    /// The two fields `testARequestIsOneFlatObject` does not name, at values that cannot be
    /// confused with anything else in the frame, plus the third anchor's wire spelling. A
    /// `CodingKey` swapped in *both* directions survives a round trip and dies here.
    func testARequestPutsItsSessionAndLimitOnTheWire() throws {
        let json = try fields(
            of: ClientFrame.req(
                cid: 11, .timeline(session: session, anchor: .after(524_291), limit: 137)
            )
        )
        XCTAssertEqual(json["session"] as? String, session.uuidString)
        XCTAssertEqual(json["limit"] as? Int, 137)
        XCTAssertEqual(json["anchor"] as? String, "after")
        XCTAssertEqual(json["cursor"] as? Int, 524_291)
    }

    func testTheLatestAnchorCarriesNoCursor() throws {
        let json = try fields(
            of: ClientFrame.req(cid: 1, .timeline(session: session, anchor: .latest, limit: 40))
        )
        XCTAssertEqual(json["anchor"] as? String, "latest")
        XCTAssertNil(json["cursor"], "there is no cursor to send when asking for the end")
    }

    /// An anchor name this build does not know cannot be served, and must not be quietly
    /// turned into one that can — `.latest` is the opposite end of the file from `.before`.
    /// See `TimelineAnchor.init(name:cursor:)` for why this direction throws while
    /// `TimelineItem.Kind` does not.
    func testAnUnknownAnchorIsRefused() throws {
        let json = """
        {"t":"req","cid":1,"op":"timeline.page","session":"\(session.uuidString)",\
        "anchor":"around","cursor":88,"limit":40}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClientFrame.self, from: Data(json.utf8))
        )
    }

    /// `.before` without a cursor names no offset at all. Defaulting it to zero would ask for
    /// the records before the start of the file, which is not what any caller meant.
    func testACursorlessBeforeAnchorIsRefused() throws {
        let json = """
        {"t":"req","cid":1,"op":"timeline.page","session":"\(session.uuidString)",\
        "anchor":"before","limit":40}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClientFrame.self, from: Data(json.utf8))
        )
    }

    // MARK: The page

    func testAPageRoundTrips() throws {
        let page = TimelinePage(
            session: session,
            items: [TimelineItem(id: "0#0", kind: .userTurn, status: .complete,
                                 body: .init(text: "hello"), at: "2026-08-21T00:00:00.000Z")],
            start: 0, end: 120, hasMore: true, reset: false
        )
        XCTAssertEqual(try roundTrip(ServerFrame.page(cid: 7, page)), .page(cid: 7, page))
    }

    /// Every field at a distinct, non-default value, asserted one at a time rather than by
    /// whole-value equality, so the failure names the field that moved. Two items, not one,
    /// so a reversed array is a failure rather than a no-op.
    func testAPageRoundTripsEveryFieldAtADistinctValue() throws {
        let page = TimelinePage(
            session: otherSession,
            items: [
                TimelineItem(id: "4096#0", kind: .toolCall, status: .streaming,
                             body: .init(text: "first", summary: "s", tool: "Bash",
                                         callID: "call-1", truncatedBytes: 512, isError: true),
                             at: "2026-08-21T00:00:01.000Z"),
                TimelineItem(id: "4096#1", kind: .toolResult, status: .complete,
                             body: .init(text: "second"), at: "2026-08-21T00:00:02.000Z")
            ],
            start: 4_096, end: 8_192, hasMore: true, reset: true
        )
        let frame = try roundTrip(ServerFrame.page(cid: 4_242, page))
        guard case .page(let cid, let decoded) = frame else {
            return XCTFail("a page did not decode as a page")
        }
        XCTAssertEqual(cid, 4_242)
        XCTAssertEqual(decoded.session, otherSession)
        XCTAssertEqual(decoded.items.map(\.id), ["4096#0", "4096#1"])
        XCTAssertEqual(decoded.items.first?.body.tool, "Bash")
        XCTAssertEqual(decoded.start, 4_096)
        XCTAssertEqual(decoded.end, 8_192)
        XCTAssertTrue(decoded.hasMore)
        XCTAssertTrue(decoded.reset)
    }

    /// `hasMore` and `reset` are both defaulted-away booleans, so each has to be seen carrying
    /// a value the other does not. All four combinations, because two flags that always agree
    /// would survive being decoded from each other's key.
    func testEveryCombinationOfThePageFlagsRoundTrips() throws {
        for hasMore in [false, true] {
            for reset in [false, true] {
                let page = TimelinePage(session: session, items: [], start: 1, end: 2,
                                        hasMore: hasMore, reset: reset)
                guard case .page(_, let decoded) = try roundTrip(ServerFrame.page(cid: 1, page))
                else { return XCTFail("a page did not decode as a page") }
                XCTAssertEqual(decoded.hasMore, hasMore, "hasMore lost at reset=\(reset)")
                XCTAssertEqual(decoded.reset, reset, "reset lost at hasMore=\(hasMore)")
            }
        }
    }

    /// The presence direction, and the two offsets at distinct values so a `start`/`end` key
    /// swap that a round trip cannot see shows up here.
    func testAPagePutsItsFieldsOnTheWire() throws {
        let page = try fields(of: TimelinePage(
            session: session, items: [], start: 4_096, end: 8_192, hasMore: true, reset: true
        ))
        XCTAssertEqual(page["session"] as? String, session.uuidString)
        XCTAssertEqual(page["start"] as? Int, 4_096)
        XCTAssertEqual(page["end"] as? Int, 8_192)
        XCTAssertEqual(page["hasMore"] as? Bool, true)
        XCTAssertEqual(page["reset"] as? Bool, true)
        XCTAssertNotNil(page["items"])
    }

    /// The absence direction, checked separately: a page carries up to 200 items, and the
    /// ordinary page — more history above, transcript intact — should not spend bytes saying
    /// so twice per fetch.
    func testAPageOmitsTheFlagsItDoesNotNeed() throws {
        let page = try fields(of: TimelinePage(
            session: session, items: [], start: 0, end: 0, hasMore: false, reset: false
        ))
        XCTAssertNil(page["hasMore"], "false is the default and costs nothing to omit")
        XCTAssertNil(page["reset"], "false is the default and costs nothing to omit")
        XCTAssertNotNil(page["start"], "the offsets are not optional even at zero")
        XCTAssertNotNil(page["end"], "the offsets are not optional even at zero")
    }

    /// A history fetch is not fleet state. `page` carries a correlation id and no sequence,
    /// so a client that pages back through an hour of transcript does not move the resume
    /// point it will hand the Mac on its next `hello`.
    func testAPageCarriesNoSequence() throws {
        let json = try fields(
            of: ServerFrame.page(cid: 3, TimelinePage(session: session, items: [],
                                                      start: 0, end: 0, hasMore: false,
                                                      reset: false))
        )
        XCTAssertEqual(json["t"] as? String, "page")
        XCTAssertNil(json["seq"], "a page is not a fleet event and must not be sequenced")
    }

    /// `ServerFrame`'s decoder tries its own tags first and treats anything else as a
    /// `FleetEvent` tag, which is why the two namespaces must never collide. `FleetEventTag`'s
    /// values are all dotted and the frame tags are not; `page` keeps that property.
    func testThePageTagDoesNotCollideWithAnEventTag() {
        XCTAssertFalse("page".contains("."))
        XCTAssertNil(FleetEventTag(rawValue: "page"))
    }

    // MARK: The receive cap
    //
    // Not here. The cap is a socket behaviour and the option cannot be read back —
    // `applicationProtocols` returns a copy that carries none of what was set on the
    // original (measured: `autoReplyPing` reads `false`, `maximumMessageSize` reads `0`,
    // right after both were set). It is tested through a real socket instead, in
    // `FleetSocketLoopbackTests.testAFrameAboveTheReceiveCapIsRefusedRatherThanBuffered`
    // and `testAWorstCasePageIsUnderTheReceiveCap`.
}
