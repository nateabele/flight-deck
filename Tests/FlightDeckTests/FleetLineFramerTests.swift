import Network
import XCTest
@testable import FleetKit

/// The local transport's framing, over a real unix socket. A fake would prove nothing about
/// the one thing that matters here: that Network.framework hands `receiveMessage` whole lines.
final class FleetLineFramerTests: XCTestCase {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var path = ""

    override func setUp() {
        super.setUp()
        // Short on purpose: sockaddr_un holds 103 bytes and NSTemporaryDirectory is long.
        path = "/tmp/fdlf-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        connections.forEach { $0.cancel() }
        listener?.cancel()
        unlink(path)
        // The lowered cap set by testALineLongerThanTheCapFailsTheConnection is process-wide
        // (NWProtocolFramer instantiates FleetLineFramer itself, so the cap can't be
        // per-instance) — reset it or it leaks into whichever test runs next.
        FleetLineFramer.maximumLineLength = TimelineLimits.maximumMessageSize
        super.tearDown()
    }

    /// Stands up a listener; `onMessage` sees each server-side message, `onEnd` each end.
    private func serve(maximum: Int = TimelineLimits.maximumMessageSize,
                       onMessage: @escaping (String) -> Void,
                       onEnd: @escaping (Error?) -> Void = { _ in }) throws -> NWConnection {
        let parameters = FleetSocket.lineParameters(maximumMessageSize: maximum)
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.connections.append(connection)
            connection.start(queue: .main)
            func loop() {
                connection.receiveMessage { data, _, _, error in
                    if let error { return onEnd(error) }
                    if let data { onMessage(String(decoding: data, as: UTF8.self)) }
                    loop()
                }
            }
            loop()
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        let client = NWConnection(to: .unix(path: path),
                                  using: FleetSocket.lineParameters(maximumMessageSize: maximum))
        connections.append(client)
        client.start(queue: .main)
        return client
    }

    private func send(_ text: String, _ connection: NWConnection) {
        connection.send(content: Data(text.utf8), isComplete: true, completion: .idempotent)
    }

    func testBackToBackSendsArriveAsSeparateMessages() throws {
        var got: [String] = []
        let three = expectation(description: "three")
        let client = try serve { got.append($0); if got.count == 3 { three.fulfill() } }
        send("one", client); send("two", client); send("three", client)
        wait(for: [three], timeout: 5)
        XCTAssertEqual(got, ["one", "two", "three"])
    }

    func testAFrameWhoseJSONCarriesAnEscapedNewlineSurvivesWhole() throws {
        // JSONEncoder escapes a newline inside a string as `\n` (two bytes), which is what
        // makes newline-delimited framing safe for these frames at all.
        let encoded = String(decoding: try JSONEncoder().encode(["text": "a\nb"]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\n"))
        let one = expectation(description: "one")
        var got: String?
        let client = try serve { got = $0; one.fulfill() }
        send(encoded, client)
        wait(for: [one], timeout: 5)
        XCTAssertEqual(got, encoded)
    }

    /// Bigger than any single read the stack hands the framer (8 KiB on a unix socket). The
    /// framer once only ever looked at one contiguous read, so a line with no newline inside
    /// the first 8192 bytes was never delivered — a hang, not an error, which is how a
    /// 22.9 KB fleet snapshot froze every `flightdeck` command. Every earlier test used lines
    /// of a few bytes and could not see it.
    func testALineLongerThanOneReadArrivesWhole() throws {
        let line = String(repeating: "x", count: 64 * 1024)
        let one = expectation(description: "one")
        var got: String?
        let client = try serve { got = $0; one.fulfill() }
        send(line, client)
        wait(for: [one], timeout: 3)
        XCTAssertEqual(got?.count, line.count)
        XCTAssertEqual(got, line)
    }

    /// Several large lines in one stream: after delivering one, the framer must start the next
    /// from empty, or a line would carry the previous one's bytes (or a short one go missing).
    func testBackToBackLargeLinesArriveAsSeparateMessages() throws {
        let lines = [64 * 1024, 20_000, 9_000, 3, 40_000].enumerated().map { index, size in
            String(repeating: Character(String(UnicodeScalar(UInt8(97 + index)))), count: size)
        }
        var got: [String] = []
        let all = expectation(description: "all")
        let client = try serve { got.append($0); if got.count == lines.count { all.fulfill() } }
        lines.forEach { send($0, client) }
        wait(for: [all], timeout: 3)
        XCTAssertEqual(got.map(\.count), lines.map(\.count))
        XCTAssertEqual(got, lines)
    }

    /// One line dribbled in over many small raw writes, so the framer sees it grow read by
    /// read rather than as one large buffer. A raw socket, not an `NWConnection`: the framed
    /// client appends a newline to every send, so it cannot split a line at all.
    func testALineSplitAcrossManySmallWritesArrivesWhole() throws {
        let line = String(repeating: "q", count: 30_000)
        let one = expectation(description: "one")
        var got: String?
        _ = try serve { got = $0; one.fulfill() }
        let fd = try rawConnect()
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        DispatchQueue.global().async {
            stride(from: 0, to: bytes.count, by: 997).forEach { start in
                let chunk = bytes[start..<min(start + 997, bytes.count)]
                _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                usleep(500)
            }
        }
        wait(for: [one], timeout: 3)
        XCTAssertEqual(got, line)
    }

    /// A plain blocking unix-socket client to the listener `serve` started.
    private func rawConnect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            _ = path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    func testALineLongerThanTheCapFailsTheConnection() throws {
        // Without the cap, a peer that never sends a newline makes the reader buffer forever.
        // The cap sits well above one 8 KiB read, so this only passes if the framer keeps
        // reading past the first read and fails at the real cap — a 64-byte cap fit inside
        // one read and so could pass while every line over 8 KiB hung.
        let ended = expectation(description: "ended")
        let client = try serve(maximum: 20_000, onMessage: { _ in }, onEnd: { _ in ended.fulfill() })
        send(String(repeating: "z", count: 50_000), client)
        wait(for: [ended], timeout: 3)
    }

    /// The counterpart: a line just under that same cap is still delivered, so the cap is
    /// enforced at its value and not at whatever one read happens to hold.
    func testALineJustUnderTheCapArrives() throws {
        let line = String(repeating: "y", count: 19_999)
        let one = expectation(description: "one")
        var got: String?
        let client = try serve(maximum: 20_000) { got = $0; one.fulfill() }
        send(line, client)
        wait(for: [one], timeout: 3)
        XCTAssertEqual(got, line)
    }
}
