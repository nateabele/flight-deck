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

final class EndpointBox: @unchecked Sendable { var value: [String] = [] }

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

    /// `host.info` reports the tracker's `idleSince`, so a controller can stop a box that has
    /// sat unused past its threshold.
    func testHostInfoCarriesIdleSince() throws {
        let tracker = IdleTracker(now: { Date(timeIntervalSince1970: 42) })
        let c = HostServerCore(hostName: { "mini" }, probe: probe, idle: tracker); let p = FakePeer()
        c.receive(text: try hello(), from: p)
        c.receive(text: try HostWire.encode(HostClientFrame.request(id: 3, .hostInfo)), from: p)
        let f = try p.frames()
        guard case .reply(3, .hostInfo(let info)) = f[1] else { return XCTFail("\(f)") }
        XCTAssertEqual(info.hostName, "mini")
        XCTAssertEqual(info.idleSince, Date(timeIntervalSince1970: 42))
    }

    /// The core asks its provider on every hello rather than caching one answer, because a
    /// host's addresses change under it (a laptop host joining the tailnet).
    func testHelloAckCarriesTheProvidersEndpoints() throws {
        let box = EndpointBox()
        let c = HostServerCore(hostName: { "mini" }, probe: probe, endpoints: { box.value })
        let p = FakePeer()
        box.value = ["100.100.1.2:47410", "10.0.0.5:47410"]
        c.receive(text: try hello(), from: p)
        box.value = ["10.0.0.6:47410"]
        let q = FakePeer()
        c.receive(text: try hello(), from: q)
        XCTAssertEqual(try p.frames().first, .helloAck(
            protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini",
            endpoints: ["100.100.1.2:47410", "10.0.0.5:47410"]))
        XCTAssertEqual(try q.frames().first, .helloAck(
            protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini",
            endpoints: ["10.0.0.6:47410"]))
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

    /// A 1.0 controller (from before delegation) still connects to a 1.1 host and still gets
    /// `host.info`. The hello is the 1.0 build's literal bytes, not one encoded here, so the
    /// test cannot pass by a change that moved both ends of this build together.
    func testA10HelloIsAcceptedByA11Core() throws {
        XCTAssertEqual(ProtocolVersion.current, ProtocolVersion(major: 1, minor: 1))
        let c = core(); let p = FakePeer()
        c.receive(text: #"{"caps":["host.info"],"name":"laptop","t":"hello","v":{"major":1,"minor":0}}"#, from: p)
        c.receive(text: #"{"id":2,"req":{"op":"host.info"},"t":"req"}"#, from: p)
        let f = try p.frames()
        XCTAssertEqual(f.first, .helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini"))
        guard f.count == 2, case .reply(2, .hostInfo) = f[1] else { return XCTFail("\(f)") }
        XCTAssertFalse(p.closed)
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

    /// Revoking a controller that is connected but silent (or mid-hello) must still keep it out.
    func testRevokedSlotCannotHelloAfterDisconnect() throws {
        let c = core(); let a = FakePeer()
        c.disconnect(slot: a.slot)
        c.receive(text: try hello(), from: a)
        XCTAssertTrue(a.closed)
        XCTAssertEqual(a.sent, [])
    }

    /// A revoked controller that upgraded but never spoke is not in the core's table, so the
    /// revoke could not close it. Whatever it sends next must be met with a silent close: an
    /// `err` reply would tell a revoked key that it still reaches a live host.
    func testRevokedSilentPeerIsClosedWithoutAnyReply() throws {
        let c = core()
        for text in [try HostWire.encode(HostClientFrame.request(id: 4, .hostInfo)),
                     #"{"t":"req","id":5,"req":{"op":"fleet.teleport"}}"#,
                     "{not json"] {
            let p = FakePeer()
            c.disconnect(slot: p.slot)
            c.receive(text: text, from: p)
            XCTAssertEqual(p.sent, [], "replied to a revoked slot: \(text)")
            XCTAssertTrue(p.closed)
        }
    }
}
