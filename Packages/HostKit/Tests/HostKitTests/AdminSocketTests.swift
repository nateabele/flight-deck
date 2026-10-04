import XCTest
#if canImport(Glibc)
import Glibc
#endif
@testable import HostKit

final class AdminSocketTests: XCTestCase {
    var path: String!
    // Short /tmp path on purpose: sun_path is 104 bytes on Darwin and a scratch dir can overflow it.
    override func setUp() { path = "/tmp/fdhk-\(UUID().uuidString.prefix(8)).sock" }
    override func tearDown() { unlink(path) }

    func testRequestReply() throws {
        let server = try AdminSocketServer(path: path) { req in
            req == .status ? .status(paired: 2, armedUntil: nil, listeningPort: 4711, hostName: "mini") : .failed("x")
        }
        defer { server.stop() }
        XCTAssertEqual(try AdminSocketClient.send(.status, path: path),
                       .status(paired: 2, armedUntil: nil, listeningPort: 4711, hostName: "mini"))
    }

    func testSocketIsOwnerOnly() throws {
        let server = try AdminSocketServer(path: path) { _ in .ok }; defer { server.stop() }
        var st = stat(); stat(path, &st)
        XCTAssertEqual(Int(st.st_mode) & 0o777, 0o600)
    }

    /// Review Focus 5: a crashed hostd leaves the file; the next start must rebind.
    func testStaleSocketFileIsReplaced() throws {
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = try AdminSocketServer(path: path) { _ in .ok }; defer { server.stop() }
        XCTAssertEqual(try AdminSocketClient.send(.status, path: path), .ok)
    }

    /// Replacing a stale file must never follow a symlink, or a planted link could make hostd
    /// delete an arbitrary file the user owns.
    func testSymlinkAtPathIsNotFollowedOrRemoved() throws {
        let target = "/tmp/fdhk-target-\(UUID().uuidString.prefix(8))"
        FileManager.default.createFile(atPath: target, contents: Data("keep".utf8))
        defer { unlink(target) }
        XCTAssertEqual(symlink(target, path), 0)
        XCTAssertThrowsError(try AdminSocketServer(path: path) { _ in .ok })
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        var st = stat(); XCTAssertEqual(lstat(path, &st), 0, "the link itself must survive")
    }

    func testOverlongPathThrowsInsteadOfTruncating() {
        let long = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
        XCTAssertThrowsError(try AdminSocketServer(path: long) { _ in .ok })
    }

    /// A client that connects and says nothing must not wedge the one-at-a-time accept loop.
    func testSilentClientDoesNotBlockOthers() throws {
        let server = try AdminSocketServer(path: path) { _ in .ok }; defer { server.stop() }
        let silent = socket(AF_UNIX, sockStream, 0)
        defer { close(silent) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.withCString { _ = memcpy(buf.baseAddress!, $0, strlen($0) + 1) }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(silent, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(try AdminSocketClient.send(.status, path: path, timeout: 6), .ok)
    }

    func testClientReportsNotRunning() {
        XCTAssertThrowsError(try AdminSocketClient.send(.status, path: path)) {
            XCTAssertEqual($0 as? AdminSocketError, .notRunning)
        }
    }
}
