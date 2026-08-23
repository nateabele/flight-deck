import Foundation
import Network
import XCTest
import FleetKit

/// The whole spine, end to end, in one process: a real TLS-PSK handshake, a real WebSocket,
/// real frames. The server half is driven by closures rather than by a `SessionStore`, which
/// is exactly what makes this testable at all — see Task 11's note.
final class FleetSocketLoopbackTests: XCTestCase {
    private var server: FleetSocketServer?
    private var client: FleetClient?
    private var relay: SlowHandshakeRelay?

    override func tearDown() async throws {
        client?.disconnect()
        if let server { try await onMain { server.stop() } }
        client = nil
        server = nil
        relay?.stop()
        relay = nil
    }

    private let sessionID = UUID()

    /// `FleetSocketServer.start`/`stop`/`broadcast` each assert
    /// `dispatchPrecondition(.onQueue(.main))` (see that class's doc comment) — deliberately,
    /// so nothing touches the state those calls mutate from any queue but the one
    /// `NWListener`/`NWConnection` deliver their own callbacks on. This class is deliberately
    /// NOT `@MainActor` itself: its tests block with `wait(for:)`, and blocking the main
    /// actor's own executor would starve the very callbacks the wait is waiting on — the same
    /// hazard documented on the `@MainActor` test classes that use `await fulfillment(of:)`
    /// instead. Hopping only the one call that needs to prove it is on `.main`, rather than
    /// the whole test method, keeps both promises intact.
    @MainActor
    private func onMain<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        try await body()
    }

    private func fleet(_ title: String) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "fd", path: "/w/fd", sessions: [
                WireSession(id: sessionID, title: title, agent: "claude")
            ])
        ])
    }

    /// Starts a server whose `hello` always answers with one snapshot at seq 7.
    @discardableResult
    private func startServer(
        key: FleetDeviceKey,
        hello: @escaping (FleetAttachment, Int) -> [ServerFrame],
        command: @escaping (FleetAttachment, Int, FleetCommand) -> ServerFrame = { _, cid, _ in .ack(cid: cid) }
    ) async throws -> NWEndpoint.Port {
        let server = FleetSocketServer()
        server.onHello = hello
        server.onCommand = command
        self.server = server
        return try await onMain { try await server.start(keys: [key], port: nil) }
    }

    private func connect(key: FleetDeviceKey, port: NWEndpoint.Port, lastSeq: Int = 0) -> FleetClient {
        let client = FleetClient(key: key)
        self.client = client
        client.connect(
            to: .hostPort(host: "127.0.0.1", port: port), lastSeq: lastSeq
        )
        return client
    }

    func testAPairedClientReceivesTheSnapshotItAskedFor() async throws {
        let key = FleetDeviceKey.mint()
        let expected = fleet("one")
        let port = try await startServer(key: key, hello: { _, lastSeq in
            XCTAssertEqual(lastSeq, 0)
            return [.snapshot(seq: 7, fleet: expected, reason: .initial)]
        })

        let received = expectation(description: "snapshot")
        var frames: [ServerFrame] = []
        let client = connect(key: key, port: port)
        client.onFrame = { frames.append($0); received.fulfill() }
        wait(for: [received], timeout: 10)

        XCTAssertEqual(frames, [.snapshot(seq: 7, fleet: expected, reason: .initial)])
    }

    func testLiveEventsReachAnAttachedClient() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, hello: { _, _ in
            [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)]
        })

        let sawEvent = expectation(description: "event")
        let client = connect(key: key, port: port)
        client.onFrame = { frame in
            if case .event(2, .renamed(_, "two", .user)) = frame { sawEvent.fulfill() }
        }
        // Broadcast only after the client is attached, or the frame has nowhere to go —
        // the server holds no queue for a client that has not connected yet.
        let attached = expectation(description: "attached")
        server?.onAttachedSlotsChanged = { if $0.count == 1 { attached.fulfill() } }
        wait(for: [attached], timeout: 10)
        if let server {
            try await onMain { server.broadcast(.event(seq: 2, .renamed(id: sessionID, title: "two", origin: .user))) }
        }
        wait(for: [sawEvent], timeout: 10)
    }

    func testResumingSendsTheSequenceTheClientAlreadyHas() async throws {
        let key = FleetDeviceKey.mint()
        let asked = expectation(description: "hello with lastSeq")
        let port = try await startServer(key: key, hello: { _, lastSeq in
            if lastSeq == 812 { asked.fulfill() }
            return [.snapshot(seq: 900, fleet: self.fleet("one"), reason: .seqTooOld)]
        })
        _ = connect(key: key, port: port, lastSeq: 812)
        wait(for: [asked], timeout: 10)
    }

    func testACommandIsAcknowledgedAgainstItsOwnCorrelationID() async throws {
        let key = FleetDeviceKey.mint()
        let delivered = expectation(description: "command reached the server")
        let port = try await startServer(
            key: key,
            hello: { _, _ in [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)] },
            command: { _, cid, command in
                XCTAssertEqual(command, .markRead(id: self.sessionID))
                delivered.fulfill()
                return .ack(cid: cid)
            }
        )

        let acked = expectation(description: "ack")
        let client = connect(key: key, port: port)
        var cid = 0
        client.onFrame = { frame in
            if case .snapshot = frame { cid = client.send(.markRead(id: self.sessionID)) }
            if case .ack(cid) = frame, cid != 0 { acked.fulfill() }
        }
        wait(for: [delivered, acked], timeout: 10)
    }

    /// The trust boundary again, this time through the whole stack rather than at the TLS
    /// layer alone: an unpaired device must never reach `onHello`.
    func testAnUnpairedClientNeverReachesApplicationCode() async throws {
        let port = try await startServer(key: .mint(), hello: { _, _ in
            XCTFail("an unpaired device reached the application layer")
            return []
        })
        let client = FleetClient(key: .mint())
        self.client = client
        let refused = expectation(description: "refused")
        client.onDisconnect = { _ in refused.fulfill() }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        // A refusal can also present as silence; either way `onHello` must not have run,
        // which is what the XCTFail above asserts.
        _ = XCTWaiter().wait(for: [refused], timeout: 8)
    }

    /// A listener with no paired devices must refuse everyone. This is not an edge case —
    /// it is the state the listener starts in, before the user has paired anything, so if
    /// an empty key set were somehow permissive it would be permissive at exactly the
    /// moment nobody is watching. Fail-closed here rests on there being no local identity
    /// configured anywhere: with no PSK and no certificate, the server has no credential to
    /// present and cannot complete a handshake.
    func testAListenerWithNoKeysRefusesEveryone() async throws {
        let server = FleetSocketServer()
        server.onHello = { _, _ in
            XCTFail("a listener with no keys must not reach application code")
            return []
        }
        self.server = server
        let port = try await onMain { try await server.start(keys: [], port: nil) }

        let client = FleetClient(key: .mint())
        self.client = client
        let refused = expectation(description: "refused")
        client.onDisconnect = { _ in refused.fulfill() }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        // A refusal can also present as silence; either way `onHello` must not have run,
        // which is what the XCTFail above asserts.
        _ = XCTWaiter().wait(for: [refused], timeout: 8)
    }

    /// One dropped socket must produce exactly one `onDisconnect`. Three code paths reach
    /// that closure and a single failure trips at least two of them, so without the guard the
    /// reconnect policy built on it schedules a retry per firing.
    func testDisconnectIsReportedAtMostOncePerConnection() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, hello: { _, _ in
            [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)]
        })
        let client = connect(key: key, port: port)
        let attached = expectation(description: "attached")
        server?.onAttachedSlotsChanged = { if $0.count == 1 { attached.fulfill() } }
        wait(for: [attached], timeout: 10)

        var endings = 0
        client.onDisconnect = { _ in endings += 1 }
        // Drop the socket from the far end, which is what a Mac going away looks like.
        if let server { try await onMain { server.stop() } }

        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 10)
        XCTAssertEqual(endings, 1, "onDisconnect fired \(endings) times for one drop")
    }

    /// A teardown we asked for is not a disconnection to react to. If `disconnect()` reported
    /// through `onDisconnect`, a client that raced several endpoints and cancelled the losers
    /// would immediately try to reconnect to each of them.
    func testAskingToDisconnectDoesNotReportADisconnection() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, hello: { _, _ in
            [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)]
        })
        let client = connect(key: key, port: port)
        let attached = expectation(description: "attached")
        server?.onAttachedSlotsChanged = { if $0.count == 1 { attached.fulfill() } }
        wait(for: [attached], timeout: 10)

        var endings = 0
        client.onDisconnect = { _ in endings += 1 }
        client.disconnect()

        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 10)
        XCTAssertEqual(endings, 0, "a self-initiated teardown must not read as a drop")
    }

    /// A peer that completes a handshake and then says nothing must not hold a slot open
    /// forever — that is a resource leak reachable by anyone holding a revoked-but-not-yet-
    /// deleted key.
    ///
    /// The peer speaks WebSocket for real, and that is load-bearing rather than incidental:
    /// `authDeadline` is armed from the connection's `.ready`, which on this listener means
    /// the TLS-PSK handshake *and* the WebSocket upgrade have both finished. The raw-TLS
    /// connection this test used to open never reached `.ready` at all, so after the deadline
    /// split it would have been proving `handshakeDeadline` under `authDeadline`'s name.
    ///
    /// `handshakeDeadline` is pinned long for the same reason, so the only thing that can
    /// close this connection is silence after `.ready` — a single deadline of any length, or
    /// one still armed at `accept`, would pass a version of this test that did not say so.
    func testASilentClientIsDroppedAfterTheAuthDeadline() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        server.authDeadline = 0.5
        server.handshakeDeadline = 60
        server.onHello = { _, _ in XCTFail("the silent peer must never have said hello"); return [] }
        self.server = server
        let port = try await onMain { try await server.start(keys: [key], port: nil) }

        // Hand-rolled WebSocket, the same two building blocks `FleetSocket` uses internally,
        // because `FleetClient` cannot be told to stay quiet: it sends `hello` from `.ready`.
        // It never reaches `attached`, so `onAttachedSlotsChanged` never fires for it — that
        // callback only reports peers the server actually let in. The proof the server dropped
        // it is a pending `receiveMessage` completing: Network.framework does not surface a
        // peer's close through `stateUpdateHandler` on this side, only through a receive that
        // was already waiting when the drop happened.
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = FleetTLS.clientParameters(key: key)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let silent = NWConnection(
            to: .url(URL(string: "wss://127.0.0.1:\(port.rawValue)/")!), using: parameters
        )

        let dropped = expectation(description: "dropped")
        silent.receiveMessage { _, _, _, _ in dropped.fulfill() }
        silent.start(queue: .main)
        wait(for: [dropped], timeout: 10)
        silent.cancel()
    }

    /// The regression the deadline split exists for, and it was the Mac's fault rather than
    /// the phone's: `accept` fires when TCP connects, so an `authDeadline` armed there is spent
    /// on a TLS-PSK handshake and a WebSocket upgrade the peer cannot hurry and during which it
    /// has no socket to say `hello` on. The twin of this on the pairing listener was measured
    /// against a booted simulator as `flow:failed_connect @5.273s` — five seconds of handshake
    /// against a five-second deadline. Here it is worse to diagnose, not better: a phone that
    /// pairs fine and then cannot attach, with nothing logged at either end, because the Mac
    /// just hangs up.
    ///
    /// The handshake is made slow by `SlowHandshakeRelay` rather than by the client, because no
    /// client can do it: `NWConnection` starts its handshake the instant its transport is up.
    /// The relay's TCP connection reaches the Mac at t=0 and its first TLS byte four
    /// `authDeadline`s later, which is the exact shape of the field failure and deterministic
    /// to the millisecond rather than dependent on a slow link.
    ///
    /// It attaches for real rather than asserting "was not dropped": `FleetClient` sends
    /// `hello` from `.ready` with nothing in between, which is what the short deadline is
    /// entitled to expect of it and what makes five seconds *after* `.ready` generous.
    func testAPeerWhoseHandshakeOutlastsTheAuthDeadlineStillAttaches() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        server.authDeadline = 0.5
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)] }
        self.server = server
        let port = try await onMain { try await server.start(keys: [key], port: nil) }

        let relay = SlowHandshakeRelay(upstream: port, holdingTheFirstBytesFor: 2)
        self.relay = relay
        let relayPort = try await relay.start()

        let attached = expectation(description: "attached")
        server.onAttachedSlotsChanged = { if $0.count == 1 { attached.fulfill() } }

        var handshakeTook: TimeInterval = 0
        let dialled = Date()
        let client = FleetClient(key: key)
        self.client = client
        client.onReady = { handshakeTook = Date().timeIntervalSince(dialled) }
        client.onDisconnect = { _ in
            XCTFail("the Mac hung up on a peer that was still handshaking")
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: relayPort), lastSeq: 0)

        wait(for: [attached], timeout: 15)
        // Without this the test could pass having proved nothing: a relay that failed to hold
        // the bytes produces an ordinary fast handshake, which the unfixed server attaches
        // perfectly well.
        XCTAssertGreaterThan(
            handshakeTook, server.authDeadline,
            "the handshake was not actually held past the deadline it has to outlast"
        )
    }

    /// The hole the split would otherwise open. If `authDeadline` only starts at `.ready`, a
    /// peer that opens a TCP connection and never sends a byte of TLS reaches `.ready` never —
    /// so with nothing armed at `accept` it would hold one of the sixteen pending slots until
    /// the app quit, which is exactly the leak `authDeadline` was added to close.
    ///
    /// `authDeadline` is pinned long so the only thing that can close this connection is the
    /// accept-time bound. Plain TCP with no TLS options at all, because that is the peer shape
    /// in question: it completes a connection the Mac accepts and then does nothing that a
    /// handshake could ever finish.
    func testAPeerThatOpensASocketAndNeverHandshakesIsDropped() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        server.handshakeDeadline = 0.5
        server.authDeadline = 60
        server.onHello = { _, _ in [] }
        self.server = server
        let port = try await onMain { try await server.start(keys: [key], port: nil) }

        let dropped = expectation(description: "the un-handshaken socket was dropped")
        // A close arrives as EOF or as a reset depending on how far the stack got, and either
        // one can also surface on the state handler; over-fulfilment is not a failure here.
        dropped.assertForOverFulfill = false
        let squatter = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        squatter.start(queue: .main)
        squatter.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { dropped.fulfill() }
        }
        defer { squatter.cancel() }

        wait(for: [dropped], timeout: 10)
    }

    /// A connection that completed its handshake but has not said `hello` yet is not
    /// "attached", so an earlier version of `stop()` walked straight past it and left it
    /// alive with nothing holding a reference that could ever cancel it. Key rotation
    /// restarts the listener, so this happened whenever a phone was mid-handshake.
    func testStoppingCancelsAConnectionThatNeverAttached() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        // Both long, so no deadline can be what closes it — `stop()` has to be.
        server.authDeadline = 60
        server.handshakeDeadline = 60
        server.onHello = { _, _ in [] }
        self.server = server
        let port = try await onMain { try await server.start(keys: [key], port: nil) }

        let silent = NWConnection(
            host: "127.0.0.1", port: port, using: FleetTLS.clientParameters(key: key)
        )
        let ready = expectation(description: "handshake complete")
        silent.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        silent.start(queue: .main)
        wait(for: [ready], timeout: 10)

        let closed = expectation(description: "server closed it")
        silent.receiveMessage { _, _, isComplete, error in
            if isComplete || error != nil { closed.fulfill() }
        }
        try await onMain { server.stop() }
        wait(for: [closed], timeout: 10)
        silent.cancel()
    }

    /// A command from a peer that has not said `hello` must close the connection rather than
    /// being answered — otherwise a peer that skipped the handshake step could drive the Mac.
    ///
    /// Not reachable through `FleetClient`: `connect(to:lastSeq:)` writes `hello` to the
    /// connection before calling `onReady`, and Network.framework preserves send order on a
    /// connection, so anything sent from `onReady` is guaranteed to arrive after `hello`, not
    /// before it. So this speaks WebSocket by hand instead — the same two building blocks
    /// `FleetSocket` uses internally (a `.url` endpoint and an `NWProtocolWebSocket` text
    /// frame over `FleetTLS.clientParameters`), just skipping `hello` entirely — to exercise
    /// the path the public API cannot reach.
    func testACommandBeforeHelloClosesTheConnection() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, hello: { _, _ in
            XCTFail("hello must not have been reached")
            return []
        }, command: { _, cid, _ in
            XCTFail("a command before hello must not be answered")
            return .ack(cid: cid)
        })

        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = FleetTLS.clientParameters(key: key)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let connection = NWConnection(
            to: .url(URL(string: "wss://127.0.0.1:\(port.rawValue)/")!), using: parameters
        )

        // Proof the server closed it, not that the client gave up on its own: a pending
        // receive completing, same idiom as the other raw-connection tests in this file.
        let closed = expectation(description: "closed")
        connection.receiveMessage { _, _, isComplete, error in
            if isComplete || error != nil { closed.fulfill() }
        }
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let data = try! JSONEncoder().encode(ClientFrame.cmd(cid: 1, .markRead(id: UUID())))
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
        connection.start(queue: .main)
        wait(for: [closed], timeout: 10)
        connection.cancel()
    }

    /// `cancelConnections()` — walked on every listener restart, which every arm, expiry and
    /// revocation performs — must fire `onAttachedSlotsChanged` with an empty set for a
    /// still-attached phone it is dropping, not skip the callback entirely. Skipping it left a
    /// stale "Connected" badge on screen until the next successful attach happened to
    /// overwrite the set, which on a restart with nothing yet reconnected never comes.
    func testAListenerRestartFiresAnEmptySlotSetForAStillAttachedClient() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, hello: { _, _ in
            [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)]
        })
        let client = connect(key: key, port: port)
        let attached = expectation(description: "attached")
        server?.onAttachedSlotsChanged = { if $0.count == 1 { attached.fulfill() } }
        wait(for: [attached], timeout: 10)

        let clearedWithEmptySet = expectation(description: "cleared")
        var firedWith: Set<UUID>?
        server?.onAttachedSlotsChanged = { slots in
            firedWith = slots
            clearedWithEmptySet.fulfill()
        }
        // A restart on the same port — the same operation `reloadKeys()` performs on every
        // arm, expiry and revocation.
        if let server {
            _ = try await onMain { try await server.start(keys: [key], port: port) }
        }
        wait(for: [clearedWithEmptySet], timeout: 10)
        XCTAssertEqual(
            firedWith, Set<UUID>(),
            "a listener restart must fire the drop, not skip it because nothing sent a frame to notice"
        )

        client.disconnect()
    }

    // MARK: The receive cap

    /// Builds a `page` frame whose JSON is `bytes` long, near enough. One item's `text` is the
    /// only field big enough to steer, and JSON escaping does not touch `a`.
    private func page(ofRoughly bytes: Int) -> ServerFrame {
        .page(cid: 1, TimelinePage(
            session: sessionID,
            items: [TimelineItem(id: "0#0", kind: .assistantText, status: .complete,
                                 body: .init(text: String(repeating: "a", count: bytes)))],
            start: 0, end: bytes, hasMore: false, reset: false
        ))
    }

    /// The receive cap, tested through the socket rather than by reading the option back.
    ///
    /// **Reading it back does not work and cannot be made to:**
    /// `NWParameters.defaultProtocolStack.applicationProtocols` hands out a fresh *copy* of
    /// each options object on every access — `first === first` is false — and the copy carries
    /// none of what was set on the original. Measured on this SDK: after setting
    /// `autoReplyPing = true` and `maximumMessageSize = 4_194_304`, the object read back from
    /// the stack reports `false` and `0`. An assertion on that value fails against correct
    /// code and passes against nothing, so the only honest check is what the socket does.
    ///
    /// What it does, measured: the oversize message is never delivered and the connection
    /// ends. Without the cap the same frame arrives whole, which is the unbounded allocation
    /// on a phone that setting it exists to prevent (`ws_options.h`: "A maximum message size
    /// of 0 means there is no receive limit").
    func testAFrameAboveTheReceiveCapIsRefusedRatherThanBuffered() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, hello: { _, _ in
            [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)]
        })

        let arrived = expectation(description: "the oversize page reached application code")
        arrived.isInverted = true
        let ended = expectation(description: "the connection ended")
        let client = connect(key: key, port: port)
        client.onFrame = { if case .page = $0 { arrived.fulfill() } }
        client.onDisconnect = { _ in ended.fulfill() }

        let attached = expectation(description: "attached")
        server?.onAttachedSlotsChanged = { if $0.count == 1 { attached.fulfill() } }
        wait(for: [attached], timeout: 10)
        if let server {
            let frame = page(ofRoughly: TimelineLimits.maximumMessageSize + 65_536)
            try await onMain { server.broadcast(frame) }
        }
        // The inverted expectation is waited on separately and briefly: once the connection
        // has ended there is nothing left to deliver the frame, and an inverted expectation
        // always burns its whole timeout.
        wait(for: [ended], timeout: 10)
        wait(for: [arrived], timeout: 1)
    }

    /// The other side of the same number, because a cap that refuses a legitimate page would
    /// pass the test above perfectly. A worst-case page — `maxPageBytes` of body, before JSON
    /// escaping has had its way with it — has to cross this socket intact.
    func testAWorstCasePageIsUnderTheReceiveCap() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, hello: { _, _ in
            [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)]
        })

        let arrived = expectation(description: "the page reached application code")
        let client = connect(key: key, port: port)
        client.onFrame = { frame in
            guard case .page(1, let page) = frame else { return }
            XCTAssertEqual(page.items.first?.body.text.count, TimelineLimits.maxPageBytes)
            arrived.fulfill()
        }

        let attached = expectation(description: "attached")
        server?.onAttachedSlotsChanged = { if $0.count == 1 { attached.fulfill() } }
        wait(for: [attached], timeout: 10)
        if let server {
            let frame = page(ofRoughly: TimelineLimits.maxPageBytes)
            try await onMain { server.broadcast(frame) }
        }
        wait(for: [arrived], timeout: 10)
    }
}
