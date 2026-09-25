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
        // The 64-byte cap set by testALineLongerThanTheCapFailsTheConnection is process-wide
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

    func testALineLongerThanTheCapFailsTheConnection() throws {
        // Without the cap, a peer that never sends a newline makes the reader buffer forever.
        let ended = expectation(description: "ended")
        let client = try serve(maximum: 64, onMessage: { _ in }, onEnd: { _ in ended.fulfill() })
        send(String(repeating: "z", count: 200), client)
        wait(for: [ended], timeout: 5)
    }
}
