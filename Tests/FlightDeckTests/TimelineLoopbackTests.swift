import Network
import XCTest
@testable import FleetKit
@testable import FlightDeck

/// The whole channel, in one process: a real `FleetService` over a real TLS-PSK socket,
/// answering a real request from a real `FleetClient` out of a real file on disk.
///
/// This is the plan's acceptance test. Everything below it is unit-tested in isolation; this
/// is the only place that proves the pieces are actually connected — the seam every previous
/// slice on this branch found its integration bug at.
///
/// **Every assertion here names the page it expects, not the fact that a reply arrived.** A
/// socket test is the easiest place on this branch to pass for the wrong reason: a timeout
/// that reads as success, a default-valued field that satisfies a weak assertion, a frame
/// that could have come from anywhere. So each page is checked on all four of the fields a
/// client paginates from — `start`, `end`, `hasMore`, `reset` — plus the `cid` it was asked
/// on, which is the only thing that says *this* reply answers *this* request.
@MainActor
final class TimelineLoopbackTests: XCTestCase {
    private var directory: URL!
    private var harness: FleetTestHarness!
    private var service: FleetService!
    private var client: FleetClient!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loopback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        service?.stop()
        service = nil
        harness = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// Mirrors `TimelineServiceTests.FixedTranscriptAdapter`: the real `ClaudeAdapter` derives
    /// a transcript path under `~/.claude/projects`, and a test has no business writing there.
    private struct FixedTranscriptAdapter: AgentAdapter {
        static let id: AgentID = .claude
        let url: URL?
        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: url)
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory,
                          binding: binding(for: session))
        }
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation {
            LoginInvocation(command: "", inject: nil)
        }
    }

    /// A fleet of one session, whose one tab reads from `transcript`.
    private func standUp(transcript: URL?) async throws -> Session {
        let harness = FleetTestHarness()
        self.harness = harness
        service = harness.service
        if let transcript {
            harness.store.overrideAdapter(
                FixedTranscriptAdapter(url: transcript), for: .claude, account: nil
            )
        }
        let session = harness.store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        try await harness.start()
        return session
    }

    func testAPairedClientReadsASessionsTimelineOverTheSocket() async throws {
        // A transcript on disk, three records, mapping to four items.
        let transcript = directory.appendingPathComponent("t.jsonl")
        try Data(#"""
            {"type":"user","isSidechain":false,"message":{"role":"user","content":"read it"}}
            {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"on it"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]}}
            {"type":"user","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"tu1","type":"tool_result","content":"a\nb"}]}}

            """#.utf8).write(to: transcript)

        let session = try await standUp(transcript: transcript)

        // A real client over a real handshake.
        var frames: [ServerFrame] = []
        var asked = 0
        var received: TimelinePage?
        var answeredOn: Int?
        let answered = expectation(description: "page")
        client = FleetClient(key: harness.key)
        client.onFrame = { frame in
            // Every frame, not only the page: answering a history request must put NOTHING
            // else on this socket. A `.event` here would mean the read had become a fleet
            // mutation — the one thing this whole channel was designed not to be, and the
            // thing `FleetReplicator`'s DEBUG drift check is left honest by.
            frames.append(frame)
            if case .page(let cid, let page) = frame {
                answeredOn = cid
                received = page
                answered.fulfill()
            }
        }
        client.onReady = { [weak self] in
            guard let self else { return }
            asked = self.client.send(
                FleetRequest.timeline(session: session.id, anchor: .latest, limit: 40)
            )
        }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)

        let page = try XCTUnwrap(received)
        XCTAssertEqual(answeredOn, asked, "the page must answer the cid it was asked on")
        XCTAssertEqual(page.session, session.id)
        XCTAssertEqual(page.items.map(\.kind),
                       [.userTurn, .assistantText, .toolCall, .toolResult])
        // `"<offset>#<block>"`. The user record begins the file; the assistant record begins
        // one byte past its 81-byte predecessor and carries two blocks; the tool result
        // begins one past the assistant's 184.
        XCTAssertEqual(page.items.map(\.id), ["0#0", "82#0", "82#1", "267#0"])
        XCTAssertEqual(page.items.map(\.body.text).first, "read it")
        XCTAssertEqual(page.items.last?.body.text, "a\nb")
        XCTAssertEqual(page.items.map(\.body.tool), [nil, nil, "Bash", nil],
                       "the tool is named on the call; claude's result record carries only "
                       + "the id it answers")
        XCTAssertEqual(page.items.map(\.body.callID), [nil, nil, "tu1", "tu1"],
                       "the result is paired with the call that produced it")
        // The client's whole pagination state, all four fields: content that is right on a
        // page whose cursors are wrong is a conversation it can never page past.
        XCTAssertEqual(page.start, 0, "the whole file fitted, so the page starts at its top")
        XCTAssertEqual(page.end, 401, "81 + 184 + 133 bytes of record, and the `\\n` each ends on")
        XCTAssertFalse(page.hasMore, "nothing precedes `start`")
        XCTAssertFalse(page.reset, "the file the cursor came from is the file that was read")
        // The snapshot the attach produced, then the page. Nothing else: a read is not a
        // mutation, so there is no northbound event for it to have emitted.
        XCTAssertEqual(frames.count, 2, "answering a page must emit no fleet event")
        guard case .snapshot(_, _, .initial) = frames[0] else {
            return XCTFail("the first frame must be the attach snapshot, got \(frames[0])")
        }
    }

    /// The second page is what proves the cursors survive the wire, not just the reader.
    ///
    /// The two fetches rendezvous by construction rather than by timing: the second is issued
    /// from inside the delivery of the first, so it cannot be sent until the first page has
    /// actually arrived and cannot be answered from a cursor the wire did not carry.
    func testTheCursorFromOnePageFetchesTheOneAboveIt() async throws {
        let transcript = directory.appendingPathComponent("t.jsonl")
        let lines = (0..<6).map {
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"m\#($0)"}}"#
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)

        let session = try await standUp(transcript: transcript)

        var pages: [TimelinePage] = []
        let both = expectation(description: "two pages")
        both.expectedFulfillmentCount = 2
        client = FleetClient(key: harness.key)
        client.onFrame = { [weak self] frame in
            guard case .page(_, let page) = frame else { return }
            pages.append(page)
            if pages.count == 1 {
                _ = self?.client.send(
                    FleetRequest.timeline(session: session.id,
                                          anchor: .before(page.start), limit: 3)
                )
            }
            both.fulfill()
        }
        client.onReady = { [weak self] in
            guard let self else { return }
            _ = self.client.send(
                FleetRequest.timeline(session: session.id, anchor: .latest, limit: 3)
            )
        }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [both], timeout: 15)

        // Six identical 76-byte records and the `\n` each ends on: a stride of 77.
        XCTAssertEqual(pages.map { $0.items.map(\.body.text) },
                       [["m3", "m4", "m5"], ["m0", "m1", "m2"]])
        XCTAssertEqual(pages.map { $0.items.map(\.id) },
                       [["231#0", "308#0", "385#0"], ["0#0", "77#0", "154#0"]])
        XCTAssertEqual(pages.map(\.session), [session.id, session.id])
        XCTAssertEqual(pages.map(\.start), [231, 0])
        XCTAssertEqual(pages.map(\.end), [462, 231])
        // Guarded rather than indexed straight through: a page that never arrives would
        // otherwise trap out of range and take the rest of the suite down with it, turning
        // this test's own failure into everyone else's.
        guard pages.count == 2 else {
            return XCTFail("expected two pages over the wire, got \(pages.count)")
        }
        XCTAssertEqual(pages[1].end, pages[0].start, "no gap, no overlap, across the wire")
        XCTAssertEqual(pages.map(\.hasMore), [true, false],
                       "three records precede the first page and none precede the second")
        XCTAssertEqual(pages.map(\.reset), [false, false])
    }

    func testAnUnknownSessionComesBackAsAnError() async throws {
        _ = try await standUp(transcript: nil)

        var asked = 0
        var refusedOn: Int?
        var code: String?
        let answered = expectation(description: "err")
        client = FleetClient(key: harness.key)
        client.onFrame = { frame in
            if case .err(let cid, let received) = frame {
                refusedOn = cid
                code = received
                answered.fulfill()
            }
        }
        client.onReady = { [weak self] in
            guard let self else { return }
            asked = self.client.send(
                FleetRequest.timeline(session: UUID(), anchor: .latest, limit: 40)
            )
        }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)
        // Not merely "an error": `unhandled` is what an unwired socket answers and
        // `unsupported` is what an unparseable request answers, and either of those passing
        // for this would say the request never reached the timeline at all.
        XCTAssertEqual(code, "unknown_session")
        XCTAssertEqual(refusedOn, asked, "the refusal must answer the cid it was asked on")
    }
}
