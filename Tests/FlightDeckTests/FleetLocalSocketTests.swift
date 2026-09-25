import Network
import XCTest
@testable import FleetKit

@MainActor
final class FleetLocalSocketTests: XCTestCase {
    private var server: FleetSocketServer!
    private var path = ""

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
        path = "/tmp/fdls-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        server?.stop()
        server = nil
        unlink(path)
        super.tearDown()
    }

    /// A bare line-framed client: sends raw JSON lines, collects decoded server frames.
    private func dial(onFrame: @escaping (ServerFrame) -> Void) -> NWConnection {
        let connection = NWConnection(to: .unix(path: path), using: FleetSocket.lineParameters())
        FleetSocket.receive(ServerFrame.self, from: connection, onFrame: onFrame, onEnd: { _ in })
        connection.start(queue: .main)
        return connection
    }

    func testHelloIsAnsweredAndTheAttachmentIsLocalWithItsCaller() async throws {
        var seen: FleetAttachment?
        server.onHello = { attachment, _ in
            seen = attachment
            return [.snapshot(seq: 7, fleet: FleetSnapshot(), reason: .initial)]
        }
        try await server.startLocal(path: path)
        let arrived = expectation(description: "snapshot")
        let connection = dial { if case .snapshot(7, _, _) = $0 { arrived.fulfill() } }
        FleetSocket.send(ClientFrame.hello(lastSeq: 0, device: nil, caps: [], caller: "tok"), over: connection)
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(seen?.isLocal, true)
        XCTAssertEqual(seen?.caller, "tok")
        XCTAssertNil(seen?.slot)
        connection.cancel()
    }

    func testCommandsReachOnCommandAndAreAnsweredOnTheirCid() async throws {
        server.onHello = { _, _ in [] }
        server.onCommand = { _, cid, _, reply in reply(.ack(cid: cid)) }
        try await server.startLocal(path: path)
        let acked = expectation(description: "ack")
        let connection = dial { if case .ack(42) = $0 { acked.fulfill() } }
        FleetSocket.send(ClientFrame.hello(lastSeq: 0, device: nil), over: connection)
        FleetSocket.send(ClientFrame.cmd(cid: 42, .markRead(id: UUID())), over: connection)
        await fulfillment(of: [acked], timeout: 5)
        connection.cancel()
    }

    func testTheSocketFileIsOwnerOnly() async throws {
        try await server.startLocal(path: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testStopUnlinksTheSocket() async throws {
        try await server.startLocal(path: path)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testADeadSocketFileIsReplaced() async throws {
        // What a crash leaves behind: the file, with nothing listening on it.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&address.sun_path.0, $0, 103) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Qualified: inside an `XCTestCase` a bare `bind` resolves to an instance
                // method, not the syscall.
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try await server.startLocal(path: path)
    }

    func testStartLocalRefusesALiveSocket() async throws {
        // Debug and Release, or two instances on one state dir: the second must never take
        // over the first one's socket.
        try await server.startLocal(path: path)
        let second = FleetSocketServer()
        do {
            try await second.startLocal(path: path)
            XCTFail("bound over a live socket")
        } catch FleetSocketError.inUse {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the live socket must survive")
    }

    func testAPathTooLongForSockaddrIsRefusedByName() async {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        do {
            try await server.startLocal(path: long)
            XCTFail("bound a path sockaddr_un cannot hold")
        } catch FleetSocketError.pathTooLong(let length) {
            XCTAssertEqual(length, long.utf8.count)
        } catch { XCTFail("wrong error: \(error)") }
    }
}
