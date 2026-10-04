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
}
