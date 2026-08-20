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

    override func tearDown() async throws {
        client?.disconnect()
        if let server { try await onMain { server.stop() } }
        client = nil
        server = nil
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
    func testASilentClientIsDroppedAfterTheAuthDeadline() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        server.authDeadline = 0.5
        server.onHello = { _, _ in [] }
        self.server = server
        let port = try await onMain { try await server.start(keys: [key], port: nil) }

        // A raw TLS connection that never speaks WebSocket-frames-with-a-hello, so it never
        // reaches `attached` and `onAttachedSlotsChanged` never fires for it — that callback
        // only reports peers the server actually let in. The proof the server dropped it is
        // a pending `receiveMessage` completing: Network.framework does not surface a peer's
        // close through `stateUpdateHandler` on this side, only through a receive that was
        // already waiting when the drop happened.
        let dropped = expectation(description: "dropped")
        let silent = NWConnection(
            host: "127.0.0.1", port: port, using: FleetTLS.clientParameters(key: key)
        )
        silent.receiveMessage { _, _, _, _ in dropped.fulfill() }
        silent.start(queue: .main)
        wait(for: [dropped], timeout: 10)
        silent.cancel()
    }

    /// A connection that completed its handshake but has not said `hello` yet is not
    /// "attached", so an earlier version of `stop()` walked straight past it and left it
    /// alive with nothing holding a reference that could ever cancel it. Key rotation
    /// restarts the listener, so this happened whenever a phone was mid-handshake.
    func testStoppingCancelsAConnectionThatNeverAttached() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        server.authDeadline = 60          // long, so the deadline cannot be what closes it
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
}
