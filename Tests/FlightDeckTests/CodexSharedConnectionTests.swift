import XCTest
@testable import FlightDeck

final class CodexSharedConnectionTests: XCTestCase {
    func testTheDaemonSocketIsNotInheritedByTabProcesses() {
        let fd = CodexSharedConnection.openSocket()
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
    }

    func testClientFramesMaskEveryPayloadByteAcrossLengthBoundaries() {
        for count in [0, 1, 125, 126, 65535, 65536] {
            let payload = Data(repeating: 65, count: count)
            let mask: [UInt8] = [1, 2, 3, 4]
            let frame = CodexSharedConnection.frame(payload, mask: mask)
            XCTAssertEqual(frame[0], 0x81)
            XCTAssertEqual(frame[1] & 0x80, 0x80)
            let offset = count < 126 ? 2 : count <= 65535 ? 4 : 10
            XCTAssertEqual(Array(frame[offset..<(offset + 4)]), mask)
            let decoded = Data(frame.dropFirst(offset + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] })
            XCTAssertEqual(decoded, payload)
        }
    }
}
