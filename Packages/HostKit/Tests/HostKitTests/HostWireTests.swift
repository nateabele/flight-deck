import XCTest
@testable import HostKit

final class HostWireTests: XCTestCase {
    func testClientFramesRoundTrip() throws {
        let frames: [HostClientFrame] = [
            .hello(protocolVersion: .current, capabilities: [.hostInfo], controllerName: "laptop"),
            .request(id: 7, .hostInfo),
        ]
        for f in frames {
            XCTAssertEqual(try HostWire.decode(HostClientFrame.self, from: HostWire.encode(f)), f)
        }
    }

    func testServerFramesRoundTrip() throws {
        let info = HostInfo(hostName: "mini", platform: "macOS", osVersion: "26.5", arch: "arm64",
                            hostdVersion: "1.0", xcode: ["26.4"], docker: nil, diskFreeBytes: 42)
        let frames: [HostServerFrame] = [
            .helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini"),
            .helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini",
                      endpoints: ["100.100.1.2:47410", "[fd7a::1]:47410"]),
            .refused(reason: .majorVersionMismatch(host: .init(major: 2, minor: 0))),
            .reply(id: 7, .hostInfo(info)),
            .error(id: 7, code: "unsupported", message: "nope"),
        ]
        for f in frames {
            XCTAssertEqual(try HostWire.decode(HostServerFrame.self, from: HostWire.encode(f)), f)
        }
    }

    /// The tag is a stable string on the wire: a Linux hostd and a Mac controller built months
    /// apart must agree, so pin it rather than trusting synthesized Codable.
    func testWireShapeIsPinned() throws {
        XCTAssertEqual(try HostWire.encode(HostClientFrame.request(id: 1, .hostInfo)),
                       #"{"id":1,"req":{"op":"host.info"},"t":"req"}"#)
    }

    /// An unknown frame tag from a newer peer decodes to an error, not a crash, so minor-version
    /// skew degrades instead of killing the connection.
    func testUnknownTagThrows() {
        XCTAssertThrowsError(try HostWire.decode(HostClientFrame.self, from: #"{"t":"future"}"#))
    }

    func testVersionOrdering() {
        XCTAssertLessThan(ProtocolVersion(major: 1, minor: 0), ProtocolVersion(major: 1, minor: 1))
        XCTAssertLessThan(ProtocolVersion(major: 1, minor: 9), ProtocolVersion(major: 2, minor: 0))
    }

    func testHelloAndAckShapesArePinned() throws {
        XCTAssertEqual(
            try HostWire.encode(HostClientFrame.hello(protocolVersion: .current, capabilities: [.hostInfo], controllerName: "laptop")),
            #"{"caps":["host.info"],"name":"laptop","t":"hello","v":{"major":1,"minor":1}}"#)
        XCTAssertEqual(
            try HostWire.encode(HostServerFrame.helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini")),
            #"{"caps":["host.info"],"name":"mini","t":"helloAck","v":{"major":1,"minor":1}}"#)
    }

    /// A host's own addresses ride on helloAck so a controller that only ever reached it over
    /// the LAN still learns its tailnet address before it leaves the room. Pinned populated;
    /// the empty case above is pinned *without* the key, so a host with nothing to advertise
    /// sends exactly the bytes a build from before this field did.
    func testHelloAckEndpointsArePinned() throws {
        XCTAssertEqual(
            try HostWire.encode(HostServerFrame.helloAck(
                protocolVersion: .current, capabilities: [.hostInfo], hostName: "mini",
                endpoints: ["100.100.1.2:47410", "[fd7a::1]:47410"])),
            #"{"caps":["host.info"],"endpoints":["100.100.1.2:47410","[fd7a::1]:47410"],"name":"mini","t":"helloAck","v":{"major":1,"minor":1}}"#)
    }

    /// A hostd built before `endpoints` existed sends no key at all. That must decode to an
    /// empty list, not throw: a throw here is a controller that can no longer reach any host
    /// it has not updated.
    func testHelloAckWithoutEndpointsStillDecodes() throws {
        let ack = try HostWire.decode(HostServerFrame.self,
            from: #"{"t":"helloAck","v":{"major":1,"minor":0},"caps":["host.info"],"name":"mini"}"#)
        XCTAssertEqual(ack, .helloAck(protocolVersion: ProtocolVersion(major: 1, minor: 0), capabilities: [.hostInfo],
                                      hostName: "mini", endpoints: []))
    }

    func testRefusedAndErrShapesArePinned() throws {
        XCTAssertEqual(
            try HostWire.encode(HostServerFrame.refused(reason: .majorVersionMismatch(host: .init(major: 2, minor: 0)))),
            #"{"reason":{"host":{"major":2,"minor":0},"kind":"majorVersionMismatch"},"t":"refused"}"#)
        XCTAssertEqual(
            try HostWire.encode(HostServerFrame.error(id: 7, code: "unsupported", message: "nope")),
            #"{"code":"unsupported","id":7,"message":"nope","t":"err"}"#)
    }

    /// A nil `docker` is omitted, not `null`: pinned so a Linux and a Mac hostd agree.
    func testHostInfoShapeIsPinned() throws {
        var info = HostInfo(hostName: "mini", platform: "macOS", osVersion: "26.5", arch: "arm64",
                            hostdVersion: "1.0", xcode: ["26.4"], docker: nil, diskFreeBytes: 42)
        XCTAssertEqual(try HostWire.encode(info),
            #"{"arch":"arm64","diskFreeBytes":42,"hostName":"mini","hostdVersion":"1.0","osVersion":"26.5","platform":"macOS","xcode":["26.4"]}"#)
        info.docker = "27.0"
        XCTAssertTrue(try HostWire.encode(info).contains(#""docker":"27.0""#))
    }

    /// `idleSince` came after the first hostds shipped: their `host.info` lacks it, and must
    /// still decode (as "no idle report"), not fail the whole reply.
    func testHostInfoFromAnOlderHostdHasNoIdleSince() throws {
        let old = #"{"arch":"arm64","diskFreeBytes":1,"hostName":"h","hostdVersion":"0.1.0","osVersion":"x","platform":"Linux","xcode":[]}"#
        XCTAssertNil(try JSONDecoder().decode(HostInfo.self, from: Data(old.utf8)).idleSince)
    }

    /// Present, it round-trips; absent (nil), it is omitted like `docker`, so the pinned shape
    /// above is unchanged for a host that reports none.
    func testHostInfoCarriesIdleSince() throws {
        var info = HostInfo(hostName: "h", platform: "Linux", osVersion: "x", arch: "arm64",
                            hostdVersion: "0.1.0", xcode: [], docker: nil, diskFreeBytes: 1)
        XCTAssertFalse(try HostWire.encode(info).contains("idleSince"))
        info.idleSince = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(try HostWire.decode(HostInfo.self, from: HostWire.encode(info)), info)
    }

    /// Capabilities are the additive mechanism for minor-version skew: an unknown one must be
    /// dropped, not fail the whole handshake.
    func testUnknownCapabilityIsDropped() throws {
        let hello = try HostWire.decode(HostClientFrame.self,
            from: #"{"t":"hello","v":{"major":1,"minor":1},"caps":["host.info","future.cap"],"name":"x"}"#)
        XCTAssertEqual(hello, .hello(protocolVersion: .init(major: 1, minor: 1), capabilities: [.hostInfo], controllerName: "x"))
        let ack = try HostWire.decode(HostServerFrame.self,
            from: #"{"t":"helloAck","v":{"major":1,"minor":1},"caps":["host.info","future.cap"],"name":"x"}"#)
        XCTAssertEqual(ack, .helloAck(protocolVersion: .init(major: 1, minor: 1), capabilities: [.hostInfo], hostName: "x"))
    }
}
