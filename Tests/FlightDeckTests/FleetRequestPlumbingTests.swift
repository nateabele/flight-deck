import Network
import XCTest
@testable import FleetKit

/// The `req` arm of the server's frame switch. A real listener, a real client, a real
/// TLS-PSK handshake — the same shape `FleetSocketLoopbackTests` uses, because a fake
/// transport here would prove nothing about the thing that ships.
///
/// Two rules are load-bearing and neither is visible in normal operation: a `req` before
/// `hello` must be refused exactly as a `cmd` is, and a reply that arrives after the phone
/// has gone must be dropped rather than written to a dead connection.
@MainActor
final class FleetRequestPlumbingTests: XCTestCase {
    private var server: FleetSocketServer!
    private var client: FleetClient!
    private var raw: RawFleetClient!
    private let key = FleetDeviceKey.mint()
    private let session = UUID()

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        raw?.stop()
        raw = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func page() -> TimelinePage {
        TimelinePage(
            session: session,
            items: [TimelineItem(id: "0#0", kind: .userTurn, status: .complete,
                                 body: .init(text: "hello"))],
            start: 0, end: 80, hasMore: true, reset: false
        )
    }

    private func start() async throws -> NWEndpoint {
        server.onHello = { _, _ in [] }
        let port = try await server.start(keys: [key], port: nil)
        return .hostPort(host: "127.0.0.1", port: port)
    }

    func testARequestIsAnsweredWithAPage() async throws {
        let endpoint = try await start()
        let expected = page()
        server.onRequest = { _, cid, request, reply in
            guard case .timeline(let id, let anchor, let limit) = request else {
                return XCTFail("wrong request")
            }
            XCTAssertEqual(id, self.session)
            XCTAssertEqual(anchor, .before(4_096))
            XCTAssertEqual(limit, 40)
            reply(.page(cid: cid, expected))
        }

        let received = expectation(description: "page")
        client = FleetClient(key: key)
        client.onReady = { [weak self] in
            guard let self else { return }
            _ = self.client.send(
                FleetRequest.timeline(session: self.session, anchor: .before(4_096), limit: 40)
            )
        }
        client.onFrame = { frame in
            if case .page(_, let page) = frame, page == expected { received.fulfill() }
        }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [received], timeout: 10)
    }

    /// The correlation id is the client's, echoed. Two fetches in flight is the ordinary case
    /// — a screen asking for older history while a poll for newer is outstanding — and a
    /// server that answered with its own numbering would let a client apply the wrong page.
    func testTwoConcurrentRequestsAreCorrelatedIndependently() async throws {
        let endpoint = try await start()
        var replies: [Int: (ServerFrame) -> Void] = [:]
        server.onRequest = { _, cid, _, reply in replies[cid] = reply }

        var cids: [Int] = []
        let both = expectation(description: "both pages")
        var seen: Set<Int> = []
        client = FleetClient(key: key)
        client.onReady = { [weak self] in
            guard let self else { return }
            cids = [
                self.client.send(FleetRequest.timeline(session: self.session, anchor: .latest, limit: 1)),
                self.client.send(FleetRequest.timeline(session: self.session, anchor: .after(9), limit: 1)),
            ]
            // Answered out of order on purpose: a page is a file read, and the second
            // request can finish first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                replies[cids[1]]?(.page(cid: cids[1], self.page()))
                replies[cids[0]]?(.page(cid: cids[0], self.page()))
            }
        }
        client.onFrame = { frame in
            if case .page(let cid, _) = frame {
                seen.insert(cid)
                if seen == Set(cids) { both.fulfill() }
            }
        }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [both], timeout: 10)
        XCTAssertEqual(cids.count, 2)
        XCTAssertNotEqual(cids[0], cids[1])
    }

    /// A `req` before `hello` is a peer that skipped the handshake step. `cmd` already
    /// refuses one — answering it would let an unattached peer drive the Mac — and a request
    /// that read a transcript would let it read one.
    ///
    /// Sent through `RawFleetClient` rather than `FleetClient`, which cannot express this:
    /// it sends `hello` from `.ready` unconditionally, and a switch to skip that would be
    /// production API on the shipping client whose only caller is this one line.
    ///
    /// `authDeadline` is pushed past this test's own timeout on purpose. Five seconds of
    /// silence is the *other* reason this server hangs up on a peer, so at the production
    /// value a build that happily answered the request would still see `ended` fulfil —
    /// reaped by a clock rather than refused by the guard under test.
    func testARequestBeforeHelloIsRefused() async throws {
        let endpoint = try await start()
        server.authDeadline = 60
        server.onRequest = { _, _, _, _ in
            XCTFail("an unattached peer's request must not reach the reader")
        }

        let ended = expectation(description: "connection ended")
        raw = RawFleetClient(key: key, endpoint: endpoint)
        raw.onEnd = { _ in ended.fulfill() }
        raw.onReady = { [weak self] in
            guard let self else { return }
            self.raw.send(ClientFrame.req(
                cid: 1, .timeline(session: self.session, anchor: .latest, limit: 1)
            ))
        }
        raw.onFrame = { frame in XCTFail("unexpected frame \(frame)") }
        raw.connect()
        await fulfillment(of: [ended], timeout: 10)
    }

    /// No reader wired is still an answer. The `.req` arm falls back to `err`/`unhandled`
    /// rather than returning in silence, and that fallback is the whole reason the code
    /// exists: a request dropped without a reply leaves the phone holding a `cid` nothing
    /// will ever land on — a spinner that never stops, with nothing on screen to say why.
    ///
    /// `onRequest` is deliberately left nil. That is the state under test, and it is the
    /// state every build of this Mac is in until the timeline reader is wired.
    func testARequestWithNoReaderWiredIsRefusedRatherThanDropped() async throws {
        let endpoint = try await start()

        let refused = expectation(description: "a reply, not silence")
        var frames: [ServerFrame] = []
        var cid = 0
        client = FleetClient(key: key)
        client.onReady = { [weak self] in
            guard let self else { return }
            cid = self.client.send(
                FleetRequest.timeline(session: self.session, anchor: .latest, limit: 1)
            )
        }
        client.onFrame = { frame in
            frames.append(frame)
            if frames.count == 1 { refused.fulfill() }
        }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [refused], timeout: 10)
        XCTAssertEqual(frames, [.err(cid: cid, code: "unhandled")])
    }

    /// One `cid`, one frame. A reader that answered twice — an error path that replies and
    /// then falls through to reply again is the ordinary way this happens — would put a page
    /// on a correlation id the client has already closed out and stopped expecting anything
    /// on.
    func testASecondReplyOnTheSameRequestIsDropped() async throws {
        let endpoint = try await start()
        server.onRequest = { _, cid, _, reply in
            reply(.page(cid: cid, self.page()))
            reply(.err(cid: cid, code: "second"))
        }

        let received = expectation(description: "one frame")
        var cid = 0
        var frames: [ServerFrame] = []
        client = FleetClient(key: key)
        client.onReady = { [weak self] in
            guard let self else { return }
            cid = self.client.send(
                FleetRequest.timeline(session: self.session, anchor: .latest, limit: 1)
            )
        }
        client.onFrame = { frame in
            frames.append(frame)
            if frames.count == 1 { received.fulfill() }
        }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [received], timeout: 10)
        // The second frame would be written immediately behind the first, over the same
        // socket, so this is far longer than it would need to arrive.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(frames, [.page(cid: cid, page())])
    }

    // MARK: - A request this build cannot parse

    /// A phone newer than the Mac fetches history with an anchor this build has never heard
    /// of. `TimelineAnchor` throws on it — correctly, since an anchor is executed rather than
    /// rendered — and before this the throw took the whole socket with it: no `err`, no close
    /// frame, just a hang-up the phone reads as a disconnect. It then reconnects, whose first
    /// frame resets `FleetConnector`'s backoff, and re-issues the fetch that killed it. A
    /// fixed one-second flap, forever.
    ///
    /// So the second half of this test is the half that matters: the `err` alone would pass
    /// even if the connection died immediately behind it.
    func testAnUnparseableRequestIsRefusedAndTheSocketSurvives() async throws {
        let endpoint = try await start()
        server.onRequest = { _, cid, _, reply in reply(.page(cid: cid, self.page())) }

        let refused = expectation(description: "err on the unparseable request")
        let answered = expectation(description: "a valid request answered on the same socket")
        raw = RawFleetClient(key: key, endpoint: endpoint)
        raw.onEnd = { _ in XCTFail("an unparseable request must not end the connection") }
        raw.onReady = { [weak self] in
            guard let self else { return }
            self.raw.send(ClientFrame.hello(lastSeq: 0, device: "a phone from next year"))
            self.raw.send(UnparseableRequest(cid: 1, session: self.session, anchor: "around"))
        }
        raw.onFrame = { [weak self] frame in
            guard let self else { return }
            switch frame {
            case .err(1, "unsupported"):
                refused.fulfill()
                // The proof the loop survived: a frame sent after the refusal, answered.
                self.raw.send(ClientFrame.req(
                    cid: 2, .timeline(session: self.session, anchor: .latest, limit: 1)
                ))
            case .page(2, self.page()):
                answered.fulfill()
            default:
                XCTFail("unexpected frame \(frame)")
            }
        }
        raw.connect()
        await fulfillment(of: [refused, answered], timeout: 10, enforceOrder: true)
    }

    /// The same rule one level up: an `op` this build has no case for throws out of
    /// `FleetRequest` exactly as an unknown anchor does, and is refused rather than hung up
    /// on for exactly the same reason.
    func testAnUnknownRequestOpIsRefusedTheSameWay() async throws {
        let endpoint = try await start()
        let refused = expectation(description: "err on the unknown op")
        raw = RawFleetClient(key: key, endpoint: endpoint)
        raw.onEnd = { _ in XCTFail("an unparseable request must not end the connection") }
        raw.onReady = { [weak self] in
            guard let self else { return }
            self.raw.send(ClientFrame.hello(lastSeq: 0, device: "a phone from next year"))
            self.raw.send(UnparseableRequest(cid: 7, session: self.session, op: "timeline.tail"))
        }
        raw.onFrame = { frame in
            if case .err(7, "unsupported") = frame { refused.fulfill() }
        }
        raw.connect()
        await fulfillment(of: [refused], timeout: 10)
    }

    /// The refusal is still a reply, so it answers the same question the parseable `.req` arm
    /// does before it answers anything: a peer that never said `hello` is hung up on. An
    /// unattached peer learning which of its guesses this Mac understands is a peer the
    /// handshake step was supposed to stop.
    func testAnUnparseableRequestBeforeHelloIsHungUpOn() async throws {
        let endpoint = try await start()
        // Same reason as `testARequestBeforeHelloIsRefused`: at the production value the
        // five-second silence reaper fulfils `ended` on its own, and the tear-down this test
        // is named for would go unasserted.
        server.authDeadline = 60
        let ended = expectation(description: "connection ended")
        raw = RawFleetClient(key: key, endpoint: endpoint)
        raw.onEnd = { _ in ended.fulfill() }
        raw.onReady = { [weak self] in
            guard let self else { return }
            self.raw.send(UnparseableRequest(cid: 4, session: self.session, anchor: "around"))
        }
        raw.onFrame = { frame in XCTFail("unexpected frame \(frame)") }
        raw.connect()
        await fulfillment(of: [ended], timeout: 10)
    }

    /// The discrimination, from the other side. Continuing a receive loop past a frame the
    /// two ends disagree about is exactly the failure the resume design exists to prevent, so
    /// only a `cid`-correlated request — stateless, and answerable in a way the peer can act
    /// on — earns the reprieve. Anything else still hangs up.
    func testAnUnparseableStateFrameStillEndsTheConnection() async throws {
        let endpoint = try await start()
        let ended = expectation(description: "connection ended")
        raw = RawFleetClient(key: key, endpoint: endpoint)
        raw.onEnd = { _ in ended.fulfill() }
        raw.onReady = { [weak self] in
            guard let self else { return }
            self.raw.send(ClientFrame.hello(lastSeq: 0, device: "a phone from next year"))
            // A `cid` and a tag this build has no case for: everything the salvage decode
            // reads, with the one value that makes it refuse to salvage.
            self.raw.send(UnknownTagFrame(cid: 3))
        }
        raw.onFrame = { frame in XCTFail("unexpected frame \(frame)") }
        raw.connect()
        await fulfillment(of: [ended], timeout: 10)
    }
}

/// A `req` frame no build of this app can decode. Two ways to be one, and the server must
/// treat them alike: an anchor whose name `TimelineAnchor` has no case for, and an `op`
/// `FleetRequest` has no case for. Written as bare JSON rather than built from `ClientFrame`
/// on purpose — the frame under test is precisely the one the shipping encoder cannot
/// produce, which is what makes it a stand-in for a phone newer than this Mac.
private struct UnparseableRequest: Encodable {
    let t = "req"
    let cid: Int
    let op: String
    let session: UUID
    let anchor: String
    let limit = 1

    init(cid: Int, session: UUID, op: String = "timeline.page", anchor: String = "latest") {
        self.cid = cid
        self.session = session
        self.op = op
        self.anchor = anchor
    }
}

/// A frame whose tag is not one of `hello`/`cmd`/`req`, carrying a `cid` so the only thing
/// separating it from a salvageable request is the tag itself.
private struct UnknownTagFrame: Encodable {
    let t = "sub"
    let cid: Int
}

/// A client that puts *bytes* on the wire rather than frames.
///
/// `FleetClient` deliberately cannot do this: every frame it sends is one this build can also
/// decode, and the whole subject here is what happens when that stops being true. Same
/// arrangement, and the same reason, as `PairingTestClient`.
private final class RawFleetClient: @unchecked Sendable {
    var onReady: (() -> Void)?
    var onFrame: ((ServerFrame) -> Void)?
    var onEnd: ((Error?) -> Void)?

    private let key: FleetDeviceKey
    private let endpoint: NWEndpoint
    private var connection: NWConnection?
    private var ended = false

    init(key: FleetDeviceKey, endpoint: NWEndpoint) {
        self.key = key
        self.endpoint = endpoint
    }

    func connect() {
        let parameters = FleetSocket.webSocketParameters(FleetTLS.clientParameters(key: key))
        let connection = NWConnection(
            to: FleetSocket.webSocketEndpoint(for: endpoint), using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        FleetSocket.receive(ServerFrame.self, from: connection) { [weak self] frame in
            guard let self, !self.ended else { return }
            self.onFrame?(frame)
        } onEnd: { [weak self] error in
            self?.finish(error)
        }
        connection.start(queue: .main)
    }

    func send<Frame: Encodable>(_ frame: Frame) {
        guard let connection else { return }
        FleetSocket.send(frame, over: connection)
    }

    /// Ends the socket without reporting it: `onEnd` means "the peer went away", which is
    /// the only reading these tests can assert on.
    func stop() {
        ended = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func finish(_ error: Error?) {
        guard !ended else { return }
        ended = true
        onEnd?(error)
    }
}
