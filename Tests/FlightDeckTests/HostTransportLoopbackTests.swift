import Foundation
import Network
import Security
import XCTest
@testable import FleetKit
import HostKit

/// The host transport on this Mac alone, run on every unit-suite pass, with no container.
///
/// Two halves. The suite tests are the Darwin-only half of the host suite choice: a Darwin
/// client cannot *offer* only 0xCCAC — `append_tls_ciphersuite` puts it in front of the default
/// PSK offer (0x00A8/A9/AF/AE) and nothing strips those — so the proof that a host connection
/// does not quietly negotiate 0x00A8 against a *Mac* host is what the two ends actually agree
/// on, checked alongside the control (the phone path still negotiating 0x00A8). The
/// `DarwinHostServer` tests drive the real macOS hostd server over loopback, on an ephemeral
/// port and a throwaway state root, never the installed hostd's.
final class HostTransportLoopbackTests: XCTestCase {
    private var listener: NWListener?
    var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: "/tmp/fdh-\(UUID().uuidString.prefix(6))")
    }

    override func tearDown() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var adminPath: String { root.appendingPathComponent("admin.sock").path }

    private func connection(to port: NWEndpoint.Port, key: FleetDeviceKey) -> NWConnection {
        NWConnection(to: HostTransport.endpoint(for: .hostPort(host: "127.0.0.1", port: port)),
                     using: HostTransport.clientParameters(key: key))
    }

    private func hello(_ name: String, capabilities: [HostCapability] = []) throws -> String {
        try HostWire.encode(HostClientFrame.hello(protocolVersion: .current,
                                                  capabilities: capabilities, controllerName: name))
    }

    /// Fulfils when `c`'s peer closes it, by end of stream or by error.
    private func closedExpectation(_ c: NWConnection, _ label: String) -> XCTestExpectation {
        let closed = expectation(description: label)
        closed.assertForOverFulfill = false
        c.receiveMessage { _, _, complete, error in if complete || error != nil { closed.fulfill() } }
        return closed
    }

    // MARK: - DarwinHostServer

    func testPairedControllerGetsHostInfo() async throws {
        let key = FleetDeviceKey.mint()
        try ControllerStore(root: root).add(.init(slot: key.slot, name: "t", secret: key.secret, pairedAt: Date()))
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }
        let c = connection(to: port, key: key)
        let ack = try await LinuxHostdInteropTests.roundTrip(c, text: hello("t", capabilities: [.hostInfo]))
        XCTAssertEqual(try HostWire.decode(HostServerFrame.self, from: ack),
                       .helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "loop"))
        c.cancel()
    }

    func testUnpairedKeyIsRefused() async throws {
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }
        let c = connection(to: port, key: .mint())
        do { _ = try await LinuxHostdInteropTests.roundTrip(c, text: "x", timeout: 5); XCTFail("stranger got through") } catch {}
        c.cancel()
    }

    /// Review Focus 2 (macOS): revoking via the admin socket closes the live connection.
    func testRevokedControllerIsDisconnected() async throws {
        let key = FleetDeviceKey.mint()
        try ControllerStore(root: root).add(.init(slot: key.slot, name: "t", secret: key.secret, pairedAt: Date()))
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }
        let c = connection(to: port, key: key)
        _ = try await LinuxHostdInteropTests.roundTrip(c, text: hello("t"))
        let closed = closedExpectation(c, "closed")
        XCTAssertEqual(try AdminSocketClient.send(.revoke(slot: key.slot), path: adminPath), .ok)
        await fulfillment(of: [closed], timeout: 2)
        c.cancel()
    }

    /// The slot comes from the handshake, per connection: with two controllers connected,
    /// revoking one closes only its socket, and the other keeps working on the listener that
    /// the revoke rebuilt. A listener that could not tell peers apart would close both or
    /// neither; one that dropped every connection on a rebind would close both.
    func testRevokingOneControllerLeavesTheOtherConnected() async throws {
        let doomed = FleetDeviceKey.mint(), kept = FleetDeviceKey.mint()
        let store = ControllerStore(root: root)
        try store.add(.init(slot: doomed.slot, name: "doomed", secret: doomed.secret, pairedAt: Date()))
        try store.add(.init(slot: kept.slot, name: "kept", secret: kept.secret, pairedAt: Date()))
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }

        let a = connection(to: port, key: doomed), b = connection(to: port, key: kept)
        defer { a.cancel(); b.cancel() }
        _ = try await LinuxHostdInteropTests.roundTrip(a, text: hello("doomed"))
        _ = try await LinuxHostdInteropTests.roundTrip(b, text: hello("kept"))

        let aClosed = closedExpectation(a, "doomed closed")
        XCTAssertEqual(try AdminSocketClient.send(.revoke(slot: doomed.slot), path: adminPath), .ok)
        await fulfillment(of: [aClosed], timeout: 2)

        // Still answering on the same socket after the revoke rebuilt the listener.
        let request = try HostWire.encode(HostClientFrame.request(id: 1, .hostInfo))
        let reply = try await send(request, over: b)
        guard case .reply(1, .hostInfo(let info)) = try HostWire.decode(HostServerFrame.self, from: reply) else {
            return XCTFail("expected host.info, got \(reply)")
        }
        XCTAssertEqual(info.hostName, "loop")

        // And the revoked key is refused by the rebuilt listener, on the same port.
        let again = connection(to: port, key: doomed)
        do { _ = try await LinuxHostdInteropTests.roundTrip(again, text: hello("doomed"), timeout: 5); XCTFail("revoked key got back in") } catch {}
        again.cancel()
    }

    @MainActor  // `PairingInitiator` defaults to, and asserts, the main queue
    func testArmThenPairWithHostProfile() async throws {
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        _ = try await server.start(); defer { server.stop() }
        guard case .armed(let codeText, _) = try AdminSocketClient.send(.arm, path: adminPath),
              let code = PairingCode(normalizing: codeText) else { return XCTFail() }
        let initiator = PairingInitiator(profile: .host)
        let paired = expectation(description: "paired")
        initiator.onPaired = { _, name in XCTAssertEqual(name, "loop"); paired.fulfill() }
        initiator.start(code: code, endpoint: .hostPort(host: "127.0.0.1", port: server.pairingPort!))
        await fulfillment(of: [paired], timeout: 15)
        // Polled, briefly: the host stores the controller from the seal's send completion,
        // which can land after the initiator has already opened the sealed key.
        try await eventually { ControllerStore(root: self.root).all().count == 1 }
        if case .status(_, let armedUntil, _, _) = try AdminSocketClient.send(.status, path: adminPath) {
            XCTAssertNil(armedUntil, "a code that paired must close its window")
        }
    }

    /// Pairing works with no restart: the sealed key opens the host listener the pairing
    /// rebuilt, and the controller's first hello replaces the placeholder name.
    @MainActor  // `PairingInitiator` defaults to, and asserts, the main queue
    func testPairedKeyConnectsAndItsHelloNamesTheController() async throws {
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }
        guard case .armed(let codeText, _) = try AdminSocketClient.send(.arm, path: adminPath),
              let code = PairingCode(normalizing: codeText) else { return XCTFail() }
        let initiator = PairingInitiator(profile: .host)
        let paired = expectation(description: "paired")
        nonisolated(unsafe) var sealed: FleetDeviceKey?
        initiator.onPaired = { key, _ in sealed = key; paired.fulfill() }
        initiator.start(code: code, endpoint: .hostPort(host: "127.0.0.1", port: server.pairingPort!))
        await fulfillment(of: [paired], timeout: 15)
        let key = try XCTUnwrap(sealed)
        try await eventually { ControllerStore(root: self.root).all().map(\.name) == ["controller"] }

        // The rebind is asynchronous to the store write; retry until the new key is accepted.
        var ack: String?
        for _ in 0..<20 where ack == nil {
            let c = connection(to: port, key: key)
            ack = try? await LinuxHostdInteropTests.roundTrip(c, text: hello("laptop"), timeout: 2)
            if ack == nil { c.cancel() }
        }
        XCTAssertNotNil(ack, "the paired key never opened the host listener")
        try await eventually {
            ControllerStore(root: self.root).all().map(\.name) == ["laptop"]
        }
    }

    /// The Darwin `PairingListener` seals before the host can check its code, so an exchange
    /// that finishes after its code stopped being live (here: closed behind the listener's back,
    /// standing in for an expiry racing the exchange) has already delivered a key. The host must
    /// store nothing and refuse that key, not leave a controller paired by a dead code.
    @MainActor  // `PairingInitiator` defaults to, and asserts, the main queue
    func testPairingThatOutlivesItsCodeIsNotStoredAndItsKeyIsRefused() async throws {
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        let port = try await server.start(); defer { server.stop() }
        guard case .armed(let codeText, _) = try AdminSocketClient.send(.arm, path: adminPath),
              let code = PairingCode(normalizing: codeText) else { return XCTFail() }
        server.window.cancel()
        let initiator = PairingInitiator(profile: .host)
        let paired = expectation(description: "paired")
        nonisolated(unsafe) var sealed: FleetDeviceKey?
        initiator.onPaired = { key, _ in sealed = key; paired.fulfill() }
        initiator.start(code: code, endpoint: .hostPort(host: "127.0.0.1", port: server.pairingPort!))
        await fulfillment(of: [paired], timeout: 15)
        let key = try XCTUnwrap(sealed)
        try await eventually { server.pairingPort == nil }   // the listener closed after the seal
        XCTAssertEqual(ControllerStore(root: root).all().count, 0)
        let c = connection(to: port, key: key)
        do { _ = try await LinuxHostdInteropTests.roundTrip(c, text: hello("late"), timeout: 5); XCTFail("a dead code's key got in") } catch {}
        c.cancel()
    }

    func testCancelArmClosesThePairingListener() async throws {
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" })
        _ = try await server.start(); defer { server.stop() }
        guard case .armed = try AdminSocketClient.send(.arm, path: adminPath) else { return XCTFail() }
        XCTAssertNotNil(server.pairingPort)
        XCTAssertEqual(try AdminSocketClient.send(.cancelArm, path: adminPath), .ok)
        XCTAssertNil(server.pairingPort)
        guard case .status(let paired, let armedUntil, let listening, let name) =
                try AdminSocketClient.send(.status, path: adminPath) else { return XCTFail() }
        XCTAssertEqual(paired, 0)
        XCTAssertNil(armedUntil)
        XCTAssertNotNil(listening)
        XCTAssertEqual(name, "loop")
    }

    /// One more text frame on an already-open connection, and its reply.
    private func send(_ text: String, over c: NWConnection) async throws -> String {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let ctx = NWConnection.ContentContext(identifier: "t", metadata: [meta])
            c.send(content: Data(text.utf8), contentContext: ctx, isComplete: true,
                   completion: .contentProcessed { _ in })
            c.receiveMessage { data, _, _, error in
                if let error { return k.resume(throwing: error) }
                k.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
            }
        }
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition never held", file: file, line: line) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Suites

    /// Starts `parameters` on an OS-assigned loopback port, echoing every message back.
    private func listen(_ parameters: NWParameters) async throws -> NWEndpoint.Port {
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            func echo() {
                connection.receiveMessage { data, context, _, error in
                    guard error == nil, let data else { return }
                    connection.send(content: data, contentContext: context ?? .defaultMessage,
                                    isComplete: true, completion: .contentProcessed { _ in })
                    echo()
                }
            }
            echo()
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(listener.port)
    }

    private static func negotiated(_ connection: NWConnection) -> (suite: UInt16, version: UInt16)? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else { return nil }
        let meta = tls.securityProtocolMetadata
        return (sec_protocol_metadata_get_negotiated_tls_ciphersuite(meta).rawValue,
                sec_protocol_metadata_get_negotiated_tls_protocol_version(meta).rawValue)
    }

    func testHostTransportNegotiatesECDHEPSKChaCha20OverTLS12() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await listen(HostTransport.listenerParameters(keys: [key]))
        let connection = connection(to: port, key: key)
        defer { connection.cancel() }
        let reply = try await LinuxHostdInteropTests.roundTrip(connection, text: "loop")
        XCTAssertEqual(reply, "loop")
        let negotiated = try XCTUnwrap(Self.negotiated(connection))
        XCTAssertEqual(negotiated.suite, 0xCCAC)
        XCTAssertEqual(negotiated.version, tls_protocol_version_t.TLSv12.rawValue)
    }

    /// The identity-recording overload the hostd uses must not change the suite either.
    func testIdentityListenerStillNegotiatesECDHEPSKChaCha20() async throws {
        let key = FleetDeviceKey.mint()
        let identities = HostTransport.PeerIdentities(queue: .main)
        let port = try await listen(HostTransport.listenerParameters(keys: [key], identities: identities))
        let connection = connection(to: port, key: key)
        defer { connection.cancel() }
        _ = try await LinuxHostdInteropTests.roundTrip(connection, text: "loop")
        XCTAssertEqual(try XCTUnwrap(Self.negotiated(connection)).suite, 0xCCAC)
    }

    func testPhonePathStillNegotiatesPSKAES128GCM() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await listen(FleetTLS.listenerParameters(keys: [key]))
        let connection = NWConnection(host: "127.0.0.1", port: port,
                                      using: FleetTLS.clientParameters(key: key))
        defer { connection.cancel() }
        let ready = expectation(description: "ready")
        connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        connection.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(Self.negotiated(connection)).suite, 0x00A8)
    }
}
