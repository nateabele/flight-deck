import Foundation
import Network
import Security
import XCTest
@testable import FleetKit

/// The §3.2 gates: Darwin's Network.framework against swift-nio-ssl (BoringSSL) on Linux.
/// Skipped unless `scripts/test-hostd-linux-interop.sh` started the Linux server and exported
/// `FD_LINUX_HOSTD_ENDPOINT` (host:port) and `FD_LINUX_HOSTD_MODE` — `test-unit.sh` runs xctest
/// directly, so a plain variable reaches the runner (no TEST_RUNNER_ prefix needed there).
///
/// Each test names the server mode it needs, because one container serves one mode: the echo
/// tests dialled at the pairing responder would fail on its bootstrap PSK, and that failure
/// would say nothing about either gate. The script fails a run in which its own mode's tests
/// were skipped, so a skip here cannot pass a gate.
final class LinuxHostdInteropTests: XCTestCase {
    static let slot = UUID(uuidString: "6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00")!
    static let secret = Data(repeating: 0x5A, count: 32)

    /// The Linux server's endpoint, or a skip unless it was started in `mode`.
    static func endpoint(mode: String) throws -> NWEndpoint {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["FD_LINUX_HOSTD_ENDPOINT"], env["FD_LINUX_HOSTD_MODE"] == mode else {
            throw XCTSkip("Linux hostd not running in \(mode) mode")
        }
        let parts = spec.split(separator: ":")
        return .hostPort(host: .init(String(parts[0])), port: .init(String(parts[1]))!)
    }

    func testEchoOverPSKWebSocket() async throws {
        let endpoint = try Self.endpoint(mode: "echo")
        let key = FleetDeviceKey(slot: Self.slot, secret: Self.secret)
        let connection = NWConnection(to: HostTransport.endpoint(for: endpoint),
                                      using: HostTransport.clientParameters(key: key))
        let reply = try await Self.roundTrip(connection, text: "ping-gate")
        XCTAssertEqual(reply, "echo:ping-gate")
        let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls!.securityProtocolMetadata)
        // 0xCCAC, not the phone's 0x00A8: BoringSSL has no 0x00A8 (`FleetTLS.hostSuites`).
        XCTAssertEqual(suite.rawValue, 0xCCAC)
        connection.cancel()
    }

    func testWrongKeyIsRefused() async throws {
        let endpoint = try Self.endpoint(mode: "echo")
        let key = FleetDeviceKey(slot: Self.slot, secret: Data(repeating: 0x00, count: 32))
        let connection = NWConnection(to: HostTransport.endpoint(for: endpoint),
                                      using: HostTransport.clientParameters(key: key))
        do {
            _ = try await Self.roundTrip(connection, text: "x", timeout: 5)
            XCTFail("a wrong PSK must not complete a WebSocket round trip")
        } catch {
            // Must be the *handshake* refusing the key. A timeout, a refused TCP connect or a
            // server that never started would all fail the round trip too, and with a bare
            // `catch {}` this test passed against a server whose TLS config could not even load.
            // Observed: `-9820` (errSSLPeerBadRecordMac), the server's bad_record_mac alert when
            // the client's Finished fails to decrypt under the server's key.
            guard case .tls(let status)? = error as? NWError else {
                return XCTFail("expected a TLS handshake failure, got \(error)")
            }
            XCTAssertEqual(status, errSSLPeerBadRecordMac, "unexpected TLS failure \(error)")
        }
        connection.cancel()
    }

    /// Gate 2: the shipped `PairingInitiator`, host profile, against the Linux
    /// `NIOPairingResponder` — SPAKE2 from the pinned BoringSSL on both ends, the bootstrap PSK
    /// over 0xCCAC (the server pins it), and the sealed key opening to exactly what the server
    /// was told to deliver. A Darwin–Darwin pass proves none of this, because both halves there
    /// are the same build of the same code.
    /// `@MainActor` because `PairingInitiator` defaults to `.main` and asserts it.
    @MainActor
    func testDarwinInitiatorPairsWithLinuxResponder() async throws {
        let endpoint = try Self.endpoint(mode: "pair")
        guard let codeText = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_CODE"],
              let code = PairingCode(normalizing: codeText) else {
            throw XCTSkip("pairing interop env not set")
        }
        let initiator = PairingInitiator(profile: .host)
        let paired = expectation(description: "paired")
        initiator.onPaired = { key, hostName in
            XCTAssertEqual(key.slot, Self.slot)          // the responder seals the slot it was given
            XCTAssertEqual(key.secret, Self.secret)
            XCTAssertEqual(hostName, "interop-host")
            paired.fulfill()
        }
        initiator.onFailure = { XCTFail("pairing failed: \($0)"); paired.fulfill() }
        initiator.start(code: code, endpoint: endpoint)
        await fulfillment(of: [paired], timeout: 30)
    }

    /// Connects, sends one text frame, returns the first text frame received.
    static func roundTrip(_ c: NWConnection, text: String, timeout: TimeInterval = 10) async throws -> String {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
            let queue = DispatchQueue(label: "interop")
            var done = false
            func finish(_ r: Result<String, Error>) { guard !done else { return }; done = true; k.resume(with: r) }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(URLError(.timedOut))) }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                    let ctx = NWConnection.ContentContext(identifier: "t", metadata: [meta])
                    c.send(content: Data(text.utf8), contentContext: ctx, isComplete: true,
                           completion: .contentProcessed { if let e = $0 { finish(.failure(e)) } })
                    c.receiveMessage { data, _, _, error in
                        if let error { return finish(.failure(error)) }
                        finish(.success(String(decoding: data ?? Data(), as: UTF8.self)))
                    }
                case .failed(let e), .waiting(let e): finish(.failure(e))
                default: break
                }
            }
            c.start(queue: queue)
        }
    }
}

/// The Darwin-only half of the host suite choice, run on every unit-suite pass, with no
/// container needed. A Darwin client cannot *offer* only 0xCCAC: `append_tls_ciphersuite` puts it
/// in front of the default PSK offer (0x00A8/A9/AF/AE) and nothing strips those. So the proof
/// that a host connection does not quietly negotiate 0x00A8 against a *Mac* host is what the
/// two ends actually agree on. It is checked here alongside the control: the phone path still
/// negotiating 0x00A8, which is what shows the host change left the phone's offer alone.
final class HostTransportLoopbackTests: XCTestCase {
    private var listener: NWListener?

    override func tearDown() {
        listener?.cancel()
        listener = nil
        super.tearDown()
    }

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
        let connection = NWConnection(
            to: HostTransport.endpoint(for: .hostPort(host: "127.0.0.1", port: port)),
            using: HostTransport.clientParameters(key: key)
        )
        defer { connection.cancel() }
        let reply = try await LinuxHostdInteropTests.roundTrip(connection, text: "loop")
        XCTAssertEqual(reply, "loop")
        let negotiated = try XCTUnwrap(Self.negotiated(connection))
        XCTAssertEqual(negotiated.suite, 0xCCAC)
        XCTAssertEqual(negotiated.version, tls_protocol_version_t.TLSv12.rawValue)
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
