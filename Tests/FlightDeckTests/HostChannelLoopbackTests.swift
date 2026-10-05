import Foundation
import Network
import XCTest
@testable import FleetKit
@testable import FlightDeck
import HostKit

/// Byte channels over the real macOS host transport on loopback: binary WebSocket messages
/// into `DarwinHostServer.onBinary` and back out through `DarwinHostPeer.send(binary:)`,
/// first from a raw `NWConnection`, then from `HostLink.openChannel()`. The host's mux is
/// wired here by hand, the way C8's router will wire it.
@MainActor
final class HostChannelLoopbackTests: XCTestCase {
    /// One host mux per peer, created on the peer's first binary message.
    private final class HostMuxes: @unchecked Sendable {
        private let lock = NSLock()
        private var muxes: [ObjectIdentifier: ChannelMux] = [:]
        private var waiters: [CheckedContinuation<ChannelMux, Never>] = []

        func receive(_ data: Data, from peer: DarwinHostPeer) {
            lock.lock()
            let mux: ChannelMux
            var woken: [CheckedContinuation<ChannelMux, Never>] = []
            if let known = muxes[ObjectIdentifier(peer)] {
                mux = known
            } else {
                mux = ChannelMux(role: .host) { [weak peer] in peer?.send(binary: $0) }
                muxes[ObjectIdentifier(peer)] = mux
                woken = waiters
                waiters = []
            }
            lock.unlock()
            for waiter in woken { waiter.resume(returning: mux) }
            mux.receive(binary: data)
        }

        /// The first peer's mux, once its first binary message has arrived.
        func first() async -> ChannelMux {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let mux = muxes.values.first {
                    lock.unlock()
                    return continuation.resume(returning: mux)
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/tmp/fdc-\(UUID().uuidString.prefix(6))")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func server(_ key: FleetDeviceKey, _ muxes: HostMuxes,
                        probe: HostInfoProbe? = nil) async throws -> (DarwinHostServer, NWEndpoint.Port) {
        try ControllerStore(root: root).add(.init(slot: key.slot, name: "t", secret: key.secret, pairedAt: Date()))
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" }, probe: probe)
        server.onBinary = { peer, data in muxes.receive(data, from: peer) }
        return (server, try await server.start())
    }

    /// Echoes one channel: reads to EOF, writes back "<what it read>!", finishes.
    private nonisolated static func echo(on mux: ChannelMux, _ id: ChannelID) async throws {
        let channel = try await mux.accept(id)
        var got = Data()
        while let chunk = try await channel.read() { got.append(chunk) }
        try await channel.write(got + Data("!".utf8))
        await channel.finish()
    }

    private nonisolated static func sendBinary(_ data: Data, on c: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        c.send(content: data, contentContext: .init(identifier: "t", metadata: [meta]),
               isComplete: true, completion: .contentProcessed { _ in })
    }

    /// The next binary message, with its opcode, so a frame sent as text fails the test.
    private nonisolated static func receiveBinary(on c: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { k in
            c.receiveMessage { data, context, _, error in
                if let error { return k.resume(throwing: error) }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                guard meta?.opcode == .binary, let data else { return k.resume(throwing: URLError(.cannotParseResponse)) }
                k.resume(returning: data)
            }
        }
    }

    func testRawBinaryMessageRoundTripsThroughDarwinHostServer() async throws {
        let key = FleetDeviceKey.mint(), muxes = HostMuxes()
        let (server, port) = try await server(key, muxes); defer { server.stop() }
        let c = NWConnection(to: HostTransport.endpoint(for: .hostPort(host: "127.0.0.1", port: port)),
                             using: HostTransport.clientParameters(key: key))
        defer { c.cancel() }
        // A hello first, only because it is the existing way to wait for `.ready`.
        _ = try await LinuxHostdInteropTests.roundTrip(c, text: try HostWire.encode(HostClientFrame.hello(
            protocolVersion: .current, capabilities: [.hostInfo], controllerName: "t")))

        Self.sendBinary(ChannelFrame(channel: 1, kind: .data, payload: Data("ping".utf8)).encoded(), on: c)
        Self.sendBinary(ChannelFrame(channel: 1, kind: .eof).encoded(), on: c)
        let host = await muxes.first()
        try await Self.echo(on: host, 1)

        let data = try ChannelFrame(decoding: try await Self.receiveBinary(on: c))
        XCTAssertEqual(data, ChannelFrame(channel: 1, kind: .data, payload: Data("ping!".utf8)))
        let eof = try ChannelFrame(decoding: try await Self.receiveBinary(on: c))
        XCTAssertEqual(eof, ChannelFrame(channel: 1, kind: .eof))
    }

    /// Channel bytes do not queue behind a slow request on the same connection. `host.info`
    /// runs on the peer's queue and can take ~7 s; binary delivered there stalled every
    /// transfer for as long, and a handler waiting on channel bytes from that queue would
    /// have deadlocked. Here every probe command takes 2 s, and the echo must come back first.
    func testSlowHostInfoDoesNotDelayAChannel() async throws {
        let key = FleetDeviceKey.mint(), muxes = HostMuxes()
        let slow = HostInfoProbe(stateRoot: root, hostdVersion: "t") { _, _ in
            Thread.sleep(forTimeInterval: 2)
            return nil
        }
        let (server, port) = try await server(key, muxes, probe: slow); defer { server.stop() }
        let c = NWConnection(to: HostTransport.endpoint(for: .hostPort(host: "127.0.0.1", port: port)),
                             using: HostTransport.clientParameters(key: key))
        defer { c.cancel() }
        _ = try await LinuxHostdInteropTests.roundTrip(c, text: try HostWire.encode(HostClientFrame.hello(
            protocolVersion: .current, capabilities: [.hostInfo], controllerName: "t")))

        let request = try HostWire.encode(HostClientFrame.request(id: 1, .hostInfo))
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        c.send(content: Data(request.utf8), contentContext: .init(identifier: "t", metadata: [meta]),
               isComplete: true, completion: .contentProcessed { _ in })
        let started = Date()
        Self.sendBinary(ChannelFrame(channel: 1, kind: .data, payload: Data("ping".utf8)).encoded(), on: c)
        Self.sendBinary(ChannelFrame(channel: 1, kind: .eof).encoded(), on: c)
        let host = await muxes.first()
        try await Self.echo(on: host, 1)

        // The next message must be the echo, binary; the host.info reply (text) fails this.
        let data = try ChannelFrame(decoding: try await Self.receiveBinary(on: c))
        XCTAssertEqual(data, ChannelFrame(channel: 1, kind: .data, payload: Data("ping!".utf8)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the channel waited for host.info")
    }

    /// The controller's half: a channel from `HostLink.openChannel()` reaches the host's mux,
    /// and the answer comes back on it; when the link drops, the channel fails rather than
    /// waiting forever.
    func testHostLinkOpenChannelRoundTripsAndFailsOnDrop() async throws {
        let key = FleetDeviceKey.mint(), muxes = HostMuxes()
        let (server, port) = try await server(key, muxes)
        let link = HostLink(record: .init(slot: key.slot, name: "loop", serviceName: "loop-none",
                                          endpoints: ["127.0.0.1:\(port)"], platform: nil, pairedAt: Date()),
                            key: key, controllerName: "test")
        defer { link.stop(); server.stop() }
        do { _ = try await link.openChannel(); XCTFail("opened a channel while offline") } catch {
            XCTAssertEqual(error as? HostLinkError, .offline)
        }
        link.start()
        try await waitUntil { if case .online = link.state { true } else { false } }

        let channel = try await link.openChannel()
        XCTAssertEqual(channel.id % 2, 1, "the controller opens odd ids")
        try await channel.write(Data("bundle".utf8))
        await channel.finish()
        let host = await muxes.first()
        let id = channel.id
        Task.detached { try await Self.echo(on: host, id) }
        var answer = Data()
        while let chunk = try await channel.read() { answer.append(chunk) }
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "bundle!")

        let parked = try await link.openChannel()
        let failed = expectation(description: "read failed on drop")
        Task { do { _ = try await parked.read() } catch { failed.fulfill() } }
        link.stop()
        await fulfillment(of: [failed], timeout: 5)
    }
}
