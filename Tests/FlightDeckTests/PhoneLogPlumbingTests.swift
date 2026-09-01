import Network
import XCTest
@testable import FleetKit

/// The one request that travels Mac → phone, against a real listener, a real client and a
/// real TLS-PSK handshake — the same shape `FleetRequestPlumbingTests` uses, because a fake
/// transport here would prove nothing about the thing that ships.
///
/// **Three rules are load-bearing and none is visible in normal operation.** A phone that did
/// not advertise `logs` must never be *sent* one — not refused at the far end, not sent — or
/// the frame it cannot decode takes its socket with it, and every already-paired handset
/// loses its Mac on the day this ships. A phone that cannot parse an `ask` must refuse it on
/// its own `cid` and keep reading. And a phone that never answers at all must release the
/// caller on a deadline, or the shell command waiting on it never returns.
@MainActor
final class PhoneLogPlumbingTests: XCTestCase {
    private var server: FleetSocketServer!
    private var client: FleetClient!
    private var raw: RawPhone!
    private let key = FleetDeviceKey.mint()

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

    private func logs(_ message: String) -> WirePhoneLogs {
        WirePhoneLogs(
            entries: [WirePhoneLogEntry(
                at: "2026-09-01T09:15:00.000+01:00", level: "notice",
                category: "prompt", message: message
            )],
            truncated: false
        )
    }

    private func start() async throws -> NWEndpoint {
        server.onHello = { _, _ in [] }
        let port = try await server.start(keys: [key], port: nil)
        return .hostPort(host: "127.0.0.1", port: port)
    }

    /// The connection id to address, taken from the `hello` that attached it. Every test here
    /// asks a *specific* connection, which is what `FleetSocketServer.request` takes and what
    /// `attachments` exists to supply.
    private func attach(
        caps: [String] = FleetCapability.supported, at endpoint: NWEndpoint
    ) async throws -> UUID {
        let attached = expectation(description: "hello")
        var id: UUID?
        server.onHello = { client, _ in
            id = client.id
            attached.fulfill()
            return []
        }
        client = FleetClient(key: key, deviceName: "iPhone", caps: caps)
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [attached], timeout: 10)
        return try XCTUnwrap(id)
    }

    // MARK: - The round trip

    func testAPhoneAnswersALogRequestOnTheMacsOwnCorrelationID() async throws {
        let endpoint = try await start()
        let id = try await attach(at: endpoint)
        let expected = logs("prompt session=x derived=toolu_1 mac=toolu_1 shown=toolu_1")

        // The phone half, played by the shipping client: it hears the `ask`, answers on the
        // `cid` the Mac chose, and nothing here invents a number of its own.
        client.onFrame = { [weak self] frame in
            guard case .phoneRequest(let cid, .logs(let seconds, let limit)) = frame else {
                return XCTFail("unexpected frame \(frame)")
            }
            XCTAssertEqual(seconds, 600)
            XCTAssertEqual(limit, PhoneLogLimits.maxEntries)
            self?.client.answer(.logs(cid: cid, expected))
        }

        let answered = expectation(description: "answered")
        var result: Result<WirePhoneLogs, FleetRequestError>?
        server.request(.logs(seconds: 600, limit: PhoneLogLimits.maxEntries), of: id) {
            result = $0
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .success(expected))
    }

    /// Two fetches in flight — two phones, or one asked twice — must not cross. The reply
    /// carries the Mac's own `cid` and nothing else correlates them.
    func testTwoRequestsToOnePhoneAreCorrelatedIndependently() async throws {
        let endpoint = try await start()
        let id = try await attach(at: endpoint)
        let first = logs("first")
        let second = logs("second")

        var asked: [Int] = []
        client.onFrame = { [weak self] frame in
            guard case .phoneRequest(let cid, _) = frame else { return }
            asked.append(cid)
            guard asked.count == 2 else { return }
            // Answered backwards on purpose: reading a log is I/O and the second ask can
            // finish first.
            self?.client.answer(.logs(cid: asked[1], second))
            self?.client.answer(.logs(cid: asked[0], first))
        }

        let both = expectation(description: "both")
        both.expectedFulfillmentCount = 2
        var byRequest: [String: WirePhoneLogs] = [:]
        server.request(.logs(seconds: 10, limit: 1), of: id) {
            if case .success(let logs) = $0 { byRequest["first"] = logs }
            both.fulfill()
        }
        server.request(.logs(seconds: 20, limit: 1), of: id) {
            if case .success(let logs) = $0 { byRequest["second"] = logs }
            both.fulfill()
        }
        await fulfillment(of: [both], timeout: 10)
        XCTAssertEqual(byRequest["first"], first)
        XCTAssertEqual(byRequest["second"], second)
        XCTAssertEqual(asked.count, 2)
        XCTAssertNotEqual(asked[0], asked[1])
    }

    /// A phone that will not answer says so on the `cid`, and the code reaches the caller
    /// verbatim rather than being folded into a generic failure.
    func testARefusalReachesTheCallerWithThePhonesOwnCode() async throws {
        let endpoint = try await start()
        let id = try await attach(at: endpoint)
        client.onFrame = { [weak self] frame in
            guard case .phoneRequest(let cid, _) = frame else { return }
            self?.client.answer(.refused(cid: cid, code: "unreadable"))
        }

        let answered = expectation(description: "answered")
        var result: Result<WirePhoneLogs, FleetRequestError>?
        server.request(.logs(seconds: 60, limit: 10), of: id) { result = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .failure(.server(code: "unreadable")))
    }

    // MARK: - A peer that cannot be asked

    /// **The compatibility guarantee, and the reason `caps` exists at all.**
    ///
    /// A phone built before `ServerFrame.phoneRequest` existed has no case for that tag: its
    /// decoder falls through to the `event` arm, finds no `seq`, throws — and a throw on that
    /// side ends the socket. So the Mac must refuse *without sending anything*, and the second
    /// assertion is the one that matters: an implementation that sent the frame and let the
    /// far end deal with it would pass a test that only checked the returned error.
    func testAPhoneThatDidNotAdvertiseLogsIsRefusedWithoutBeingSentAnything() async throws {
        let endpoint = try await start()
        let id = try await attach(caps: [], at: endpoint)
        client.onFrame = { frame in
            XCTFail("a phone that claimed no capabilities must be sent nothing: \(frame)")
        }

        let answered = expectation(description: "answered")
        var result: Result<WirePhoneLogs, FleetRequestError>?
        server.request(.logs(seconds: 60, limit: 10), of: id) { result = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .failure(.server(code: "unsupported_peer")))
        // Long enough for a frame written in the same breath to have arrived.
        try await Task.sleep(for: .milliseconds(300))
    }

    /// A connection id that is not attached — a phone that left between the listing and the
    /// fetch, which is the ordinary race for a diagnostic taken from a shell.
    func testAskingAConnectionThatIsGoneAnswersDisconnectedSynchronously() async throws {
        _ = try await start()
        var result: Result<WirePhoneLogs, FleetRequestError>?
        server.request(.logs(seconds: 60, limit: 10), of: UUID()) { result = $0 }
        // Synchronously, not on a callback: `FleetConnector.request` documents the same
        // asymmetry, and a caller that has to wait for "there is nobody there" waits for a
        // deadline that teaches it nothing.
        XCTAssertEqual(result, .failure(.disconnected))
    }

    /// A phone that hears the ask and simply never replies — asleep, backgrounded, or gone
    /// without the socket noticing. Without the deadline the completion is never resolved and
    /// `scripts/answer-trigger.sh logs` sits at a blank prompt for the life of the app.
    func testAPhoneThatNeverAnswersReleasesTheCallerOnTheDeadline() async throws {
        let endpoint = try await start()
        server.askDeadline = 0.3
        let id = try await attach(at: endpoint)
        client.onFrame = { _ in }

        let answered = expectation(description: "answered")
        var result: Result<WirePhoneLogs, FleetRequestError>?
        server.request(.logs(seconds: 60, limit: 10), of: id) { result = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .failure(.server(code: "timed_out")))
    }

    /// A socket that dies with a fetch outstanding must answer it, not drop it. The same rule
    /// `FleetConnector.drainPending` keeps for the other direction, and for the same reason.
    func testAPhoneLeavingMidFetchResolvesTheCallerAsDisconnected() async throws {
        let endpoint = try await start()
        server.askDeadline = 60
        let id = try await attach(at: endpoint)
        client.onFrame = { [weak self] _ in self?.client.disconnect() }

        let answered = expectation(description: "answered")
        var result: Result<WirePhoneLogs, FleetRequestError>?
        server.request(.logs(seconds: 60, limit: 10), of: id) { result = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .failure(.disconnected))
    }

    // MARK: - A request the phone cannot parse

    /// The mirror of `testAnUnknownRequestOpIsRefusedTheSameWay`, on the half of the wire that
    /// just gained a request.
    ///
    /// A Mac newer than the phone asks for something `PhoneRequest` has no case for. Its
    /// decoder throws — correctly, since a request that cannot be understood cannot be
    /// answered — and without `FleetClient`'s salvage the throw takes the socket with it: no
    /// reply, no close frame, a bare hang-up the phone reads as a disconnect, a reconnect, and
    /// the same unanswerable question again. A one-second flap, forever.
    ///
    /// Driven from `RawMac` rather than `FleetSocketServer`, for the reason
    /// `FleetRequestPlumbingTests` drives its mirror from `RawFleetClient`: the frame under
    /// test is precisely the one this build's encoder cannot produce.
    ///
    /// The second half is the half that matters — the refusal alone would pass even if the
    /// connection died immediately behind it.
    func testAnUnparseableAskIsRefusedAndTheSocketSurvives() async throws {
        let mac = RawMac(key: key)
        let endpoint = try await mac.start()
        defer { mac.stop() }

        let refused = expectation(description: "refused on the unparseable ask")
        let answered = expectation(description: "a valid ask answered on the same socket")
        client = FleetClient(key: key)
        client.onDisconnect = { _ in XCTFail("an unparseable ask must not end the connection") }
        client.onFrame = { [weak self] frame in
            guard case .phoneRequest(let cid, _) = frame else { return }
            self?.client.answer(.logs(cid: cid, WirePhoneLogs(entries: [], truncated: false)))
        }
        var replies: [ClientFrame] = []
        mac.onFrame = { frame in
            switch frame {
            case .refused(9_001, "unsupported"):
                replies.append(frame)
                refused.fulfill()
                // The proof the loop survived: a frame sent after the refusal, answered.
                mac.send(ServerFrame.phoneRequest(cid: 2, .logs(seconds: 1, limit: 1)))
            case .logs(2, _):
                replies.append(frame)
                answered.fulfill()
            default:
                break
            }
        }
        mac.onReady = { mac.send(UnparseableAsk(cid: 9_001)) }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [refused, answered], timeout: 10, enforceOrder: true)
        XCTAssertEqual(replies.count, 2)
    }

    /// The discrimination, from the phone's side: only an `ask` earns the reprieve. A state
    /// frame this build cannot parse still ends the connection, because continuing past one is
    /// exactly the silent disagreement the resume design exists to prevent.
    func testAnUnparseableStateFrameStillEndsThePhonesConnection() async throws {
        let mac = RawMac(key: key)
        let endpoint = try await mac.start()
        defer { mac.stop() }

        let ended = expectation(description: "connection ended")
        client = FleetClient(key: key)
        client.onDisconnect = { _ in ended.fulfill() }
        client.onFrame = { frame in XCTFail("unexpected frame \(frame)") }
        // A `cid` and a tag this build has no case for: everything the salvage decode reads,
        // with the one value that makes it refuse to salvage.
        mac.onReady = { mac.send(UnknownServerTag(cid: 3)) }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [ended], timeout: 10)
    }

    // MARK: - What the Mac learns from `hello`

    func testAnAttachmentCarriesWhatThePhoneClaimed() async throws {
        let endpoint = try await start()
        _ = try await attach(caps: [FleetCapability.logs], at: endpoint)
        let attachments = server.attachments
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.name, "iPhone")
        XCTAssertEqual(attachments.first?.caps, [FleetCapability.logs])
    }

    /// Every phone in the field right now is this one: a `hello` with no `caps` key at all.
    /// It must attach exactly as it always did — the Mac would otherwise stop talking to every
    /// already-paired device on upgrade — and be listed as claiming nothing.
    func testAPhoneThatSendsNoCapsAttachesAndClaimsNothing() async throws {
        let endpoint = try await start()
        var connection: UUID?
        let attached = expectation(description: "hello")
        server.onHello = { client, _ in
            connection = client.id
            attached.fulfill()
            return []
        }
        raw = RawPhone(key: key, endpoint: endpoint)
        raw.onReady = { [weak self] in self?.raw.send(OldHello(lastSeq: 0, device: "iPhone")) }
        raw.connect()
        await fulfillment(of: [attached], timeout: 10)
        XCTAssertNotNil(connection)
        XCTAssertEqual(server.attachments.first?.caps, [])
    }
}

/// An `ask` no build of this app can decode: an `op` `PhoneRequest` has no case for. Written
/// as bare JSON rather than built from `ServerFrame` on purpose — the frame under test is
/// precisely the one the shipping encoder cannot produce.
private struct UnparseableAsk: Encodable {
    let t = "ask"
    let cid: Int
    let op = "phone.screenshot"
}

/// A server frame whose tag is not one this build knows, carrying a `cid` so the only thing
/// separating it from a salvageable `ask` is the tag itself.
private struct UnknownServerTag: Encodable {
    let t = "beacon"
    let cid: Int
}

/// The `hello` every phone in the field sends: `lastSeq` and `device`, and no `caps` key at
/// all. `ClientFrame` cannot produce it any more — it writes `caps` whenever it is non-empty
/// — which is exactly why this is bare JSON.
private struct OldHello: Encodable {
    let t = "hello"
    let lastSeq: Int
    let device: String
}

/// A phone that puts *bytes* on the wire rather than frames. Same arrangement, and the same
/// reason, as `FleetRequestPlumbingTests`'s `RawFleetClient`: `FleetClient` deliberately
/// cannot send a frame this build could not also decode.
private final class RawPhone: @unchecked Sendable {
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

/// A Mac that puts *bytes* on the wire rather than frames — the mirror of `RawPhone`, and of
/// `FleetRequestPlumbingTests`'s `RawFleetClient`.
///
/// `FleetSocketServer` deliberately cannot do this: every frame it sends is one this build can
/// also decode, and the whole subject of the two tests that use this is what happens when that
/// stops being true. One connection at a time, which is all a salvage test needs.
private final class RawMac: @unchecked Sendable {
    var onReady: (() -> Void)?
    var onFrame: ((ClientFrame) -> Void)?

    private let key: FleetDeviceKey
    private var listener: NWListener?
    private var connection: NWConnection?

    init(key: FleetDeviceKey) {
        self.key = key
    }

    func start() async throws -> NWEndpoint {
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.listenerParameters(keys: [key])
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                // `.ready` is the first moment a frame can be written — the same rule
                // `FleetSocketServer` states about its own `authDeadline`.
                if case .ready = state { self?.onReady?() }
            }
            FleetSocket.receive(ClientFrame.self, from: connection) { [weak self] frame in
                self?.onFrame?(frame)
            } onEnd: { _ in }
            connection.start(queue: .main)
        }
        return try await withCheckedThrowingContinuation { continuation in
            // Resumed exactly once: `.ready` and `.failed` are both terminal for this purpose
            // and either can arrive, so the flag is what keeps a second one from trapping.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    resumed = true
                    continuation.resume(
                        returning: .hostPort(host: "127.0.0.1", port: port)
                    )
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func send<Frame: Encodable>(_ frame: Frame) {
        guard let connection else { return }
        FleetSocket.send(frame, over: connection)
    }

    func stop() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }
}
