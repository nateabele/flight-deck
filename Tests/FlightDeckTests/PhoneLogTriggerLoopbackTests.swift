import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// The whole `logs` chain in one process: a unix socket a shell can reach, `AnswerTrigger`,
/// `FleetService`, `FleetSocketServer`, a real TLS-PSK handshake, and the shipping
/// `FleetClient` playing the phone.
///
/// **Every other test of this feature substitutes one of those, and that is the gap this
/// closes.** `AnswerTriggerTests` stubs the fleet, `PhoneLogPlumbingTests` stubs the trigger,
/// and either would stay green if the two were wired to each other wrongly — a `logs` op that
/// reached no service, a service whose `attachedClients` never included the phone, or a socket
/// that answered before the phone did. The request that goes in here is byte-for-byte the one
/// `scripts/answer-trigger.sh logs` sends.
@MainActor
final class PhoneLogTriggerLoopbackTests: XCTestCase {
    private var harness: FleetTestHarness!
    private var client: FleetClient!
    /// Named `triggerSocket`, not `socket`: a stored property called `socket` shadows the
    /// `socket(2)` syscall `roundTrip` opens its own connection with.
    private var triggerSocket: AnswerTriggerSocket!
    private var socketRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // **Under `/tmp` rather than `NSTemporaryDirectory()`**, for the reason
        // `AnswerTriggerTests` gives: a unix socket path has 103 bytes and a per-process
        // temporary directory spends most of them before the name starts.
        socketRoot = URL(fileURLWithPath: "/tmp/flight-deck-trigger", isDirectory: true)
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        harness = FleetTestHarness()
    }

    override func tearDown() {
        triggerSocket?.stop()
        triggerSocket = nil
        client?.disconnect()
        client = nil
        harness = nil
        super.tearDown()
    }

    /// Where the socket client's reply lands. A class because the read runs off the main queue
    /// and a captured `var` cannot be written from one — the same arrangement
    /// `AnswerTriggerTests.Received` has.
    private final class Received: @unchecked Sendable {
        var text: String?
    }

    /// One connect / send / read / close, in the shape `nc -U` does it — which is the only
    /// client `scripts/answer-trigger.sh` has.
    private nonisolated static func roundTrip(_ request: String, to path: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: AnswerTriggerSocket.maxPathLength + 1) {
                _ = strlcpy($0, path, AnswerTriggerSocket.maxPathLength + 1)
            }
        }
        let joined = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard joined == 0 else { return nil }
        var outgoing = Array((request + "\n").utf8)
        guard write(fd, &outgoing, outgoing.count) == outgoing.count else { return nil }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            reply.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(UInt8(ascii: "\n")) { break }
        }
        return String(data: reply, encoding: .utf8)
    }

    /// A phone attached to the harness's real listener, answering log requests with `logs`.
    private func attachPhone(
        caps: [String] = FleetCapability.supported, answering logs: WirePhoneLogs
    ) async throws {
        let port = try await harness.start()
        let attached = expectation(description: "attached")
        // `attachedClients` is what the trigger reads, so waiting on it — rather than on the
        // client's own `.ready` — is what makes the fetch below deterministic.
        client = FleetClient(key: harness.key, deviceName: "iPhone", caps: caps)
        client.onFrame = { [weak self] frame in
            guard case .phoneRequest(let cid, _) = frame else { return }
            self?.client.answer(.logs(cid: cid, logs))
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        // Polled rather than hooked: `FleetService` owns `onHello` and a test that replaced it
        // would be testing its own wiring instead of the service's.
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(10)
            while self.harness.service.attachedClients.isEmpty, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            attached.fulfill()
        }
        await fulfillment(of: [attached], timeout: 15)
        XCTAssertEqual(harness.service.attachedClients.count, 1)
    }

    /// The trigger and its socket over the live service, with the file write redirected off
    /// the developer's own `~/Library/Logs/flight-deck-phone.log`.
    private func openTrigger(appendingTo url: URL) throws -> URL {
        let trigger = AnswerTrigger(store: harness.store)
        trigger.prompts.lifecycleSink = { _ in }
        trigger.phones = harness.service
        trigger.appendPhoneLogs = { logs, device in
            PhoneLogFile.append(logs, device: device, to: url)
        }
        let path = socketRoot.appendingPathComponent("\(UUID().uuidString).sock")
        triggerSocket = AnswerTriggerSocket(url: path) { line, reply in
            trigger.handle(line, then: reply)
        }
        try triggerSocket.start()
        return path
    }

    func testTheShellFetchesAPhonesLogEndToEnd() async throws {
        let entry = WirePhoneLogEntry(
            at: "2026-09-01T09:15:00.000+01:00", level: "notice", category: "prompt",
            message: "prompt session=abc derived=toolu_1 mac=toolu_2 shown=none"
        )
        try await attachPhone(answering: WirePhoneLogs(entries: [entry], truncated: false))
        let logFile = socketRoot.appendingPathComponent("\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logFile) }
        let path = try openTrigger(appendingTo: logFile)

        let answered = expectation(description: "the shell gets its reply")
        let received = Received()
        DispatchQueue.global().async {
            // Byte-for-byte what `scripts/answer-trigger.sh logs` sends.
            received.text = Self.roundTrip(#"{"op":"logs"}"#, to: path.path)
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 20)

        let text = try XCTUnwrap(received.text)
        let reply = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["entries"] as? Int, 1)
        XCTAssertEqual(reply["path"] as? String, PhoneLogFile.fileURL.path)
        let devices = try XCTUnwrap(reply["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.first?["device"] as? String, "iPhone")

        // The reply is only true if the file it claims is already written — the fetch is
        // appended before the row is recorded, precisely so a caller reading `entries` can
        // then read the file and find them.
        let written = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(written.contains(#"fetch device="iPhone" entries=1"#))
        XCTAssertTrue(written.contains("prompt session=abc derived=toolu_1 mac=toolu_2 shown=none"))
    }

    /// **The compatibility case, end to end.** A phone built before this feature sends a
    /// `hello` claiming nothing, and the whole chain has to survive it: the Mac must refuse
    /// without putting a frame on that socket, the shell must be told which phone and why, and
    /// — the part only this test can see — the phone must still be attached afterwards.
    ///
    /// That last assertion is the one that matters. An implementation that sent the frame
    /// anyway would still answer the shell something plausible; what it would also do is hang
    /// that handset up, on a Mac it is paired to, every time anyone ran this command.
    func testAPhoneThatCannotBeAskedIsNamedAndKeepsItsConnection() async throws {
        try await attachPhone(
            caps: [], answering: WirePhoneLogs(entries: [], truncated: false)
        )
        client.onFrame = { frame in
            XCTFail("a phone that claimed no capabilities must be sent nothing: \(frame)")
        }
        let ended = expectation(description: "not disconnected")
        ended.isInverted = true
        client.onDisconnect = { _ in ended.fulfill() }

        let logFile = socketRoot.appendingPathComponent("\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logFile) }
        let path = try openTrigger(appendingTo: logFile)

        let answered = expectation(description: "the shell gets its reply")
        let received = Received()
        DispatchQueue.global().async {
            received.text = Self.roundTrip(#"{"op":"logs","seconds":120}"#, to: path.path)
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 20)

        let text = try XCTUnwrap(received.text)
        let reply = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "no_logs")
        XCTAssertEqual(reply["seconds"] as? Int, 120)
        let devices = try XCTUnwrap(reply["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.first?["error"] as? String, "unsupported_peer")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logFile.path),
            "a refusal must not write a block to the file"
        )
        // Long enough for a frame written in the same breath to have reached the phone and
        // killed its socket.
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertEqual(harness.service.attachedClients.count, 1)
    }
}
