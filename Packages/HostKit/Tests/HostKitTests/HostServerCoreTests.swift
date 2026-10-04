import XCTest
@testable import HostKit

final class FakePeer: HostPeer, @unchecked Sendable {
    let slot: UUID; var sent: [String] = []; var closed = false
    init(slot: UUID = UUID()) { self.slot = slot }
    func send(text: String) { sent.append(text) }
    func close() { closed = true }
    func frames() throws -> [HostServerFrame] { try sent.map { try HostWire.decode(HostServerFrame.self, from: $0) } }
}

/// The callback is @Sendable (Swift 6), so it cannot capture a local var.
final class NamedBox: @unchecked Sendable { var named: (UUID, String)? }

final class HostServerCoreTests: XCTestCase {
    let probe = HostInfoProbe(stateRoot: FileManager.default.temporaryDirectory, hostdVersion: "1.0") { _, _ in nil }
    func core() -> HostServerCore { HostServerCore(hostName: { "mini" }, probe: probe) }
    func hello(_ v: ProtocolVersion = .current) throws -> String {
        try HostWire.encode(HostClientFrame.hello(protocolVersion: v, capabilities: [.hostInfo], controllerName: "laptop"))
    }

    func testHelloThenHostInfo() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(), from: p)
        c.receive(text: try HostWire.encode(HostClientFrame.request(id: 3, .hostInfo)), from: p)
        let f = try p.frames()
        XCTAssertEqual(f[0], .helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini"))
        guard case .reply(3, .hostInfo(let info)) = f[1] else { return XCTFail("\(f)") }
        XCTAssertEqual(info.hostName, "mini")
    }

    func testRequestBeforeHelloIsRefusedAndClosed() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try HostWire.encode(HostClientFrame.request(id: 1, .hostInfo)), from: p)
        XCTAssertEqual(try p.frames(), [.error(id: 1, code: "no_hello", message: "send hello first")])
        XCTAssertTrue(p.closed)
    }

    func testMajorMismatchRefuses() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(.init(major: 2, minor: 0)), from: p)
        XCTAssertEqual(try p.frames(), [.refused(reason: .majorVersionMismatch(host: .current))])
        XCTAssertTrue(p.closed)
    }

    func testMinorSkewIsAccepted() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(.init(major: 1, minor: 7)), from: p)
        guard case .helloAck = try p.frames().first else { return XCTFail() }
    }

    func testGarbageIsAnErrorNotACrash() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(), from: p)
        c.receive(text: "{not json", from: p)
        XCTAssertEqual(try p.frames().last, .error(id: 0, code: "malformed", message: "unreadable frame"))
        XCTAssertFalse(p.closed)
    }

    /// A newer controller's op must cost it one answered request, not a silent hang on an
    /// id the host could not read, and not the connection.
    func testUnknownOpIsUnsupportedWithItsId() throws {
        let c = core(); let p = FakePeer()
        c.receive(text: try hello(), from: p)
        c.receive(text: #"{"t":"req","id":9,"req":{"op":"fleet.teleport"}}"#, from: p)
        XCTAssertEqual(try p.frames().last, .error(id: 9, code: "unsupported", message: "unknown request"))
        XCTAssertFalse(p.closed)
    }

    func testHelloNamesTheController() throws {
        let c = core(); let p = FakePeer(); let box = NamedBox()
        c.onControllerName = { box.named = ($0, $1) }
        c.receive(text: try hello(), from: p)
        XCTAssertEqual(box.named?.0, p.slot); XCTAssertEqual(box.named?.1, "laptop")
    }

    func testDisconnectSlotClosesOnlyThatSlot() throws {
        let c = core(); let a = FakePeer(); let b = FakePeer()
        c.receive(text: try hello(), from: a); c.receive(text: try hello(), from: b)
        c.disconnect(slot: a.slot)
        XCTAssertTrue(a.closed); XCTAssertFalse(b.closed)
    }
}
