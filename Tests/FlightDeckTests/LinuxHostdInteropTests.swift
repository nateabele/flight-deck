import Foundation
import Network
import Security
import XCTest
@testable import FleetKit
import HostKit

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

    /// The `serve`-mode hostd, or nil unless the script started one.
    static func endpoint() -> NWEndpoint? { try? endpoint(mode: "serve") }

    /// The real `serve` subcommand, seeded with `slot`/`secret` through `--test-controller`:
    /// the PSK slot authenticates, hello is acknowledged with a host name, and host.info comes
    /// back from the Linux probe — HostServerCore driven over the NIO transport, not a fake.
    func testHelloAndHostInfoAgainstLinuxHostd() async throws {
        guard let ep = Self.endpoint() else { throw XCTSkip("FD_LINUX_HOSTD_ENDPOINT not set") }
        let c = NWConnection(to: HostTransport.endpoint(for: ep), using: HostTransport.clientParameters(key: .init(slot: Self.slot, secret: Self.secret)))
        let hello = try HostWire.encode(HostClientFrame.hello(protocolVersion: .current, capabilities: [.hostInfo], controllerName: "interop"))
        let ack = try HostWire.decode(HostServerFrame.self, from: try await Self.roundTrip(c, text: hello))
        guard case .helloAck(_, _, let name) = ack else { return XCTFail("\(ack)") }
        XCTAssertFalse(name.isEmpty)
        let info = try HostWire.decode(HostServerFrame.self, from: try await Self.next(c, sending: HostWire.encode(HostClientFrame.request(id: 1, .hostInfo))))
        guard case .reply(1, .hostInfo(let i)) = info else { return XCTFail("\(info)") }
        XCTAssertEqual(i.platform, "Linux")
        c.cancel()
    }

    /// Review Focus 2: revoking through the admin socket closes the live connection promptly.
    func testRevokedControllerIsDisconnected() async throws {
        guard let ep = Self.endpoint(), let container = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_CONTAINER"] else { throw XCTSkip("env") }
        let c = NWConnection(to: HostTransport.endpoint(for: ep), using: HostTransport.clientParameters(key: .init(slot: Self.slot, secret: Self.secret)))
        _ = try await Self.roundTrip(c, text: HostWire.encode(HostClientFrame.hello(protocolVersion: .current, capabilities: [], controllerName: "interop")))
        let closed = expectation(description: "closed")
        // Several of the three signals below fire for one close; any one of them is the proof.
        closed.assertForOverFulfill = false
        c.stateUpdateHandler = { if case .cancelled = $0 { closed.fulfill() }; if case .failed = $0 { closed.fulfill() } }
        c.receiveMessage { _, _, complete, error in if complete || error != nil { closed.fulfill() } }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        p.arguments = ["exec", container, Self.hostdBinary, "revoke", Self.slot.uuidString, "--root", "/tmp/fdroot"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "revoke subcommand failed")
        await fulfillment(of: [closed], timeout: 2)
        c.cancel()
    }

    /// The whole pairing contract against `serve`: `flightdeck-hostd pair` arms through the
    /// admin socket and prints the code; the shipped host-profile initiator pairs on 47411;
    /// the sealed key then authenticates on the serve port with no restart (the key closure
    /// reads the store per handshake); the first hello renames the stored "controller"; and
    /// `pair` exits 0 because `paired` grew.
    @MainActor
    func testPairThroughServeThenHelloRenamesTheController() async throws {
        guard let ep = Self.endpoint(),
              let container = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_CONTAINER"],
              let pairingSpec = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_PAIRING_ENDPOINT"]
        else { throw XCTSkip("env") }
        let pair = Process()
        pair.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        pair.arguments = ["exec", container, Self.hostdBinary, "pair", "--root", "/tmp/fdroot"]
        let out = Pipe()
        pair.standardOutput = out
        let printed = expectation(description: "code printed")
        let buffer = LockedText()
        out.fileHandleForReading.readabilityHandler = { handle in
            if buffer.append(String(decoding: handle.availableData, as: UTF8.self)).contains("(valid 2 minutes)") {
                printed.fulfill()
            }
        }
        printed.assertForOverFulfill = false
        try pair.run()
        await fulfillment(of: [printed], timeout: 15)
        let line = try XCTUnwrap(buffer.text.split(separator: "\n").first { $0.hasPrefix("Pairing code: ") })
        let code = try XCTUnwrap(PairingCode(normalizing: String(line.dropFirst("Pairing code: ".count).prefix(14))))

        let parts = pairingSpec.split(separator: ":")
        let pairingEndpoint = NWEndpoint.hostPort(host: .init(String(parts[0])), port: .init(String(parts[1]))!)
        let initiator = PairingInitiator(profile: .host)
        let paired = expectation(description: "paired")
        var key: FleetDeviceKey?
        initiator.onPaired = { k, _ in key = k; paired.fulfill() }
        initiator.onFailure = { XCTFail("pairing failed: \($0)"); paired.fulfill() }
        initiator.start(code: code, endpoint: pairingEndpoint)
        await fulfillment(of: [paired], timeout: 30)
        let sealed = try XCTUnwrap(key)

        let c = NWConnection(to: HostTransport.endpoint(for: ep), using: HostTransport.clientParameters(key: sealed))
        let ack = try HostWire.decode(HostServerFrame.self, from: try await Self.roundTrip(c, text: HostWire.encode(
            HostClientFrame.hello(protocolVersion: .current, capabilities: [], controllerName: "interop-paired"))))
        guard case .helloAck = ack else { return XCTFail("\(ack)") }
        c.cancel()

        // The rename lands just after the ack, so poll the store rather than read it once.
        var name: String?
        for _ in 0..<20 {
            name = try Self.storedControllers(container).first { $0.slot == sealed.slot }?.name
            if name == "interop-paired" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(name, "interop-paired")
        let exited = expectation(description: "pair exited")
        DispatchQueue.global().async { pair.waitUntilExit(); exited.fulfill() }
        await fulfillment(of: [exited], timeout: 10)
        out.fileHandleForReading.readabilityHandler = nil
        XCTAssertEqual(pair.terminationStatus, 0, "pair output: \(buffer.text)")
    }

    static let hostdBinary = "/src/Packages/HostDaemonLinux/.build/debug/HostDaemonLinux"

    /// The container's controllers.json, decoded as ControllerStore writes it.
    static func storedControllers(_ container: String) throws -> [PairedController] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        p.arguments = ["exec", container, "cat", "/tmp/fdroot/controllers.json"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try JSONDecoder().decode([PairedController].self, from: data)
    }

    private final class LockedText: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        var text: String { lock.lock(); defer { lock.unlock() }; return value }
        func append(_ more: String) -> String {
            lock.lock(); defer { lock.unlock() }
            value += more
            return value
        }
    }

    /// The Linux window's attempt budget, end to end: the server was armed with a different code
    /// than the one dialled here, so three honest attempts must read wrongCode, wrongCode and
    /// then attemptsExhausted — the third reject is the one that tells the user to arm again,
    /// and the script then checks the responder exited 1. A responder that lost its verdict
    /// when the peer hung up first would keep answering `attemptsExhausted` but never exit.
    @MainActor
    func testWrongCodeExhaustsTheLinuxWindow() async throws {
        let endpoint = try Self.endpoint(mode: "pair-wrong")
        guard let codeText = ProcessInfo.processInfo.environment["FD_LINUX_HOSTD_CODE"],
              let code = PairingCode(normalizing: codeText) else {
            throw XCTSkip("pairing interop env not set")
        }
        var outcomes: [PairingInitiator.Failure] = []
        for _ in 0..<3 {
            let initiator = PairingInitiator(profile: .host)
            let done = expectation(description: "attempt")
            initiator.onPaired = { _, _ in XCTFail("a wrong code paired"); done.fulfill() }
            initiator.onFailure = { outcomes.append($0); done.fulfill() }
            initiator.start(code: code, endpoint: endpoint)
            await fulfillment(of: [done], timeout: 30)
        }
        XCTAssertEqual(outcomes, [.wrongCode, .wrongCode, .attemptsExhausted])
    }

    /// Sends one text frame on an already-ready connection and returns the next text frame.
    static func next(_ c: NWConnection, sending text: String, timeout: TimeInterval = 15) async throws -> String {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
            let queue = DispatchQueue(label: "interop.next")
            let lock = NSLock()
            var done = false
            func finish(_ r: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }; done = true; k.resume(with: r)
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(URLError(.timedOut))) }
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let ctx = NWConnection.ContentContext(identifier: "t", metadata: [meta])
            c.send(content: Data(text.utf8), contentContext: ctx, isComplete: true,
                   completion: .contentProcessed { if let e = $0 { finish(.failure(e)) } })
            c.receiveMessage { data, _, _, error in
                if let error { return finish(.failure(error)) }
                finish(.success(String(decoding: data ?? Data(), as: UTF8.self)))
            }
        }
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
