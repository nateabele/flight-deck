import Foundation
import XCTest
@testable import FlightDeck

final class CodexDaemonEndpointTests: XCTestCase {
    func testAccountControlSocketMaySymlinkToCodexPrivateRuntimeDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let control = home.appendingPathComponent("app-server-control")
        let runtime = root.appendingPathComponent("private-runtime")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let target = runtime.appendingPathComponent("socket")
        try Data().write(to: target)
        let reported = control.appendingPathComponent("app-server-control.sock")
        try FileManager.default.createSymbolicLink(at: reported, withDestinationURL: target)
        XCTAssertNoThrow(try CodexDaemonEndpoint.validatedSocketPath(reported.path, home: home))
        XCTAssertThrowsError(try CodexDaemonEndpoint.validatedSocketPath(target.path, home: home))
    }
}
