import Foundation
import HostKit
import NIOCore
import NIOEmbedded
import NIOWebSocket
@_spi(HostPairing) import PairingCore
import XCTest
@testable import HostDaemonLinux

/// The argv is the whole contract with avahi-publish: a wrong position silently advertises the
/// wrong service (`-s NAME TYPE PORT [TXT...]`), and nothing on a box without avahi would notice.
final class AvahiPublisherTests: XCTestCase {
    func testServiceArguments() {
        XCTAssertEqual(AvahiPublisher.serviceArguments(hostName: "build box", port: 47410),
                       ["-s", "build box", "_fd-host._tcp", "47410"])
    }

    func testPairingArgumentsCarryTheNameTXT() {
        XCTAssertEqual(AvahiPublisher.pairingArguments(hostName: "build box", port: 47411),
                       ["-s", "build box", "_fd-host-pair._tcp", "47411", "name=build box"])
    }

    /// Most Linux hosts (and every CI container) have no avahi; that must not stop `serve`.
    func testMissingBinaryIsASilentNoOp() {
        let publisher = AvahiPublisher(executable: "/nonexistent/avahi-publish")
        XCTAssertNil(publisher.publish(AvahiPublisher.serviceArguments(hostName: "h", port: 1)))
    }

    func testPresentBinaryIsSpawnedWithTheArguments() throws {
        let publisher = AvahiPublisher(executable: "/bin/sleep")
        let process = try XCTUnwrap(publisher.publish(["30"]))
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(process.arguments, ["30"])
        publisher.stop(process)
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }
}

/// What a Linux host advertises in `helloAck`, on the interface list a real box with Tailscale,
/// Docker and an unconfigured second NIC reports. The filter is pure so this pins it without
/// that box.
final class AdvertisedEndpointsTests: XCTestCase {
    func testLinuxFilterDropsLoopbackAndLinkLocalAndKeepsTheTailnetFirst() {
        let box: [HostEndpoints.Interface] = [
            .init(name: "lo", address: "127.0.0.1", isPointToPoint: false, isBroadcast: false, isLoopback: true),
            .init(name: "eth0", address: "192.168.1.40", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "eth1", address: "169.254.3.3", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "docker0", address: "172.17.0.1", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "tailscale0", address: "100.88.1.2", isPointToPoint: true, isBroadcast: false, isLoopback: false),
        ]
        XCTAssertEqual(LinuxHostd.advertisedEndpoints(from: box, port: HostdPorts.serve),
                       ["100.88.1.2:47410", "192.168.1.40:47410", "172.17.0.1:47410"])
    }

    /// The live walk inside the test container: whatever it finds, never loopback.
    func testLiveWalkNeverAdvertisesLoopback() {
        let live = LinuxHostd.advertisedEndpoints(from: HostEndpoints.enumerate(), port: HostdPorts.serve)
        XCTAssertFalse(live.contains { $0.hasPrefix("127.") }, "\(live)")
        XCTAssertTrue(live.allSatisfy { $0.hasSuffix(":47410") }, "\(live)")
    }
}

/// `flightdeck-hostd controllers`: the slot is what `revoke` takes, so it leads each line and
/// must be the exact `UUID` text `revoke` parses back.
final class ControllersCommandTests: XCTestCase {
    let list = [
        AdminController(slot: UUID(uuidString: "6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00")!, name: "laptop",
                        pairedAt: Date(timeIntervalSince1970: 1_791_200_000)),
        AdminController(slot: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "dana's mini",
                        pairedAt: Date(timeIntervalSince1970: 1_791_300_000)),
    ]

    func testOneLinePerControllerSlotFirst() {
        XCTAssertEqual(ControllersCommand.text(list), """
            6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00\tlaptop\t2026-10-05T11:33:20Z
            00000000-0000-4000-8000-000000000001\tdana's mini\t2026-10-06T15:20:00Z
            """)
        XCTAssertEqual(ControllersCommand.text([]), "")
    }

    func testJSONIsAnArrayOfSlotNamePairedAt() throws {
        XCTAssertEqual(try ControllersCommand.json(Array(list.prefix(1))),
            #"[{"name":"laptop","pairedAt":"2026-10-05T11:33:20Z","slot":"6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00"}]"#)
        XCTAssertEqual(try ControllersCommand.json([]), "[]")
    }
}

final class WebSocketFragmentTests: XCTestCase {
    private final class Received: @unchecked Sendable {
        let lock = NSLock()
        var texts: [String] = []
        func append(_ t: String) { lock.lock(); texts.append(t); lock.unlock() }
    }

    private func pipeline(maxMessageBytes: Int = PSKWebSocketServer.maxMessageBytes)
        throws -> (EmbeddedChannel, Received) {
        let received = Received()
        let channel = EmbeddedChannel()
        let connection = PSKWebSocketServer.Connection(identity: "x", channel: channel)
        try channel.pipeline.syncOperations.addHandlers(PSKWebSocketServer.frameHandlers(
            connection: connection, maxMessageBytes: maxMessageBytes,
            onText: { _, text in received.append(text) }, onClose: nil))
        return (channel, received)
    }

    private func frame(_ fin: Bool, _ opcode: WebSocketOpcode, _ text: String) -> WebSocketFrame {
        WebSocketFrame(fin: fin, opcode: opcode, data: ByteBuffer(string: text))
    }

    /// A message split across frames used to reach the core as its first fragment alone (and
    /// the continuations were dropped), so any large frame decoded as malformed JSON.
    func testFragmentedTextIsDeliveredWhole() throws {
        let (channel, received) = try pipeline()
        try channel.writeInbound(frame(false, .text, "hel"))
        try channel.writeInbound(frame(false, .continuation, "lo "))
        try channel.writeInbound(frame(true, .continuation, "world"))
        XCTAssertEqual(received.texts, ["hello world"])
    }

    func testOversizedAssembledMessageClosesTheConnection() throws {
        let (channel, received) = try pipeline(maxMessageBytes: 8)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        XCTAssertTrue(channel.isActive)
        try channel.writeInbound(frame(false, .text, "12345"))
        try channel.writeInbound(frame(true, .continuation, "67890"))
        XCTAssertEqual(received.texts, [])
        XCTAssertFalse(channel.isActive)
    }
}

private final class FailingWrites: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = NIOAny
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }
}

/// Swallows writes without completing them: a sealed frame still in flight, the moment between
/// sealing a key and the verdict that closes the window.
private final class HeldWrites: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = NIOAny
    var held: [EventLoopPromise<Void>?] = []
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        held.append(promise)
    }
}

final class PairingVerdictTests: XCTestCase {
    /// One code, one key: while the first controller's sealed frame is still being written,
    /// a second connection that also knows the code must be refused, not sealed the same key.
    /// The window's verdict waits on that write, so before the per-window flag there was a gap
    /// in which both sealed.
    func testASecondConfirmWhileTheFirstSealIsInFlightIsRefused() throws {
        let loop = EmbeddedEventLoop()
        let code = PairingCode.mint()
        let window = NIOPairingResponder.Window(loop: loop, code: code, key: .mint(), hostName: "h")
        let profile = NIOPairingResponder.profile

        let first = EmbeddedChannel(loop: loop)
        let held = HeldWrites()
        let second = EmbeddedChannel(loop: loop)
        let a = try XCTUnwrap(window.accept(first)), b = try XCTUnwrap(window.accept(second))
        window.ready(a); window.ready(b)
        var confirmations: [Data] = []
        for (peer, channel) in [(a, first), (b, second)] {
            let initiator = SPAKE2Session(role: .initiator, myName: profile.initiatorName,
                                          theirName: profile.responderName)
            window.handle(.pake(msg: try initiator.message(for: code)), from: peer)
            loop.run()
            let frame = try XCTUnwrap(try channel.readOutbound(as: WebSocketFrame.self))
            var data = frame.unmaskedData
            guard case .pake(let theirs) = try JSONDecoder().decode(
                PairingServerFrame.self, from: Data(data.readBytes(length: data.readableBytes)!)) else {
                return XCTFail("expected the responder's pake")
            }
            let secrets = try PairingSecrets(keyMaterial: initiator.keyMaterial(from: theirs),
                                             transcript: initiator.transcript)
            confirmations.append(secrets.initiatorConfirmation)
        }
        // The first seal's write never completes: the window is mid-delivery.
        try first.pipeline.syncOperations.addHandler(held)
        window.handle(.confirm(mac: confirmations[0]), from: a)
        loop.run()
        XCTAssertEqual(held.held.count, 1, "the first controller was sealed the key")
        XCTAssertNil(window.verdict, "still in flight")

        window.handle(.confirm(mac: confirmations[1]), from: b)
        loop.run()
        let reply = try XCTUnwrap(try second.readOutbound(as: WebSocketFrame.self))
        var data = reply.unmaskedData
        let decoded = try JSONDecoder().decode(
            PairingServerFrame.self, from: Data(data.readBytes(length: data.readableBytes)!))
        XCTAssertEqual(decoded, .reject(.attemptsExhausted), "a second controller was sealed the same key")
    }

    /// The third wrong guess must end the window even when that peer is already gone and its
    /// reject cannot be written. Before, the verdict waited on the write succeeding, so a peer
    /// that hung up first left the window open with its budget spent, answering
    /// `attemptsExhausted` forever and never telling `pair` it had burned.
    func testExhaustedVerdictSurvivesAPeerThatHungUp() throws {
        let loop = EmbeddedEventLoop()
        let code = PairingCode.mint()
        let window = NIOPairingResponder.Window(loop: loop, code: code, key: .mint(), hostName: "h")
        let profile = NIOPairingResponder.profile
        for attempt in 0..<3 {
            let channel = EmbeddedChannel(loop: loop)
            let peer = try XCTUnwrap(window.accept(channel))
            window.ready(peer)
            let initiator = SPAKE2Session(role: .initiator, myName: profile.initiatorName,
                                          theirName: profile.responderName)
            window.handle(.pake(msg: try initiator.message(for: code)), from: peer)
            // What a peer that hung up looks like from here: the reject's write fails.
            // (EmbeddedChannel completes every write, even after close, so it is failed here.)
            if attempt == 2 { try channel.pipeline.syncOperations.addHandler(FailingWrites()) }
            window.handle(.confirm(mac: Data(repeating: 0, count: 32)), from: peer)
            loop.run()
        }
        guard case .failure(let error)? = window.verdict else {
            return XCTFail("no verdict: \(String(describing: window.verdict))")
        }
        XCTAssertEqual(error as? NIOPairingResponder.Failure, .attemptsExhausted)
    }

    /// `serve` re-arms by cancelling the previous window's task, and the new window binds the
    /// same port. A task that ignored cancellation held the port until its own deadline, so
    /// every re-arm within two minutes failed to bind.
    func testCancellingTheTaskEndsTheWindowAndFreesThePort() async throws {
        let port = 47_499
        let listening = expectation(description: "listening")
        let task = Task {
            try await NIOPairingResponder.run(code: .mint(), key: .mint(), hostName: "h", port: port,
                                              deadline: 60, onListening: { listening.fulfill() })
        }
        await fulfillment(of: [listening], timeout: 10)
        let started = Date()
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled window reported success")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let again = expectation(description: "rebound")
        let second = Task {
            try await NIOPairingResponder.run(code: .mint(), key: .mint(), hostName: "h", port: port,
                                              deadline: 60, onListening: { again.fulfill() })
        }
        await fulfillment(of: [again], timeout: 10)
        second.cancel()
        _ = try? await second.value
    }
}

/// The listener's anonymous population: TCP connects that have not finished TLS and the
/// WebSocket upgrade. Raw sockets that never send a byte are exactly the squatter the cap is
/// for, and need no PSK client to drive.
final class HandshakeGateTests: XCTestCase {
    private func connectRaw(_ port: Int) throws -> Int32 {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    /// True when the server closed `fd` (EOF or reset) within `seconds`.
    private func closedByPeer(_ fd: Int32, within seconds: Double) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(seconds * 1000)) == 1 else { return false }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, 0) <= 0
    }

    func testConnectionsPastTheCapAreClosedAndTheDeadlineFreesASlot() throws {
        let server = PSKWebSocketServer(host: "127.0.0.1", port: 0, keys: { [:] },
                                        maxPending: 2, handshakeDeadline: .seconds(2),
                                        onText: { _, _ in })
        let channel = try server.start()
        defer { channel.close(promise: nil) }
        let port = try XCTUnwrap(channel.localAddress?.port)

        let a = try connectRaw(port), b = try connectRaw(port)
        defer { close(a); close(b) }
        let c = try connectRaw(port)
        defer { close(c) }
        XCTAssertTrue(closedByPeer(c, within: 1), "a connection past the cap was kept")
        XCTAssertFalse(closedByPeer(a, within: 0.2), "an admitted connection was closed early")

        // The squatters are cut at the deadline, which is what frees the slots.
        XCTAssertTrue(closedByPeer(a, within: 4), "the handshake deadline never fired")
        XCTAssertTrue(closedByPeer(b, within: 1))
        let d = try connectRaw(port)
        defer { close(d) }
        XCTAssertFalse(closedByPeer(d, within: 0.3), "a freed slot was not reusable")
    }
}
