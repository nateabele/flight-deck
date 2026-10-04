import XCTest
@testable import HostKit

final class HostInfoProbeTests: XCTestCase {
    func testGatherUsesInjectedCommandsAndDegradesWhenAbsent() {
        let probe = HostInfoProbe(stateRoot: FileManager.default.temporaryDirectory, hostdVersion: "1.0") { path, args in
            if path.hasSuffix("docker") { return "27.3.1\n" }
            return nil   // no xcodebuild, no sw_vers
        }
        let info = probe.gather()
        XCTAssertEqual(info.docker, "27.3.1")
        XCTAssertEqual(info.xcode, [])
        XCTAssertGreaterThan(info.diskFreeBytes, 0)
        XCTAssertFalse(info.hostName.isEmpty)
        #if os(Linux)
        XCTAssertEqual(info.platform, "Linux")
        #else
        XCTAssertEqual(info.platform, "macOS")
        #endif
    }

    /// A hung `docker version` (daemon wedged) must not hang host.info.
    func testRunCommandTimesOut() {
        let start = Date()
        XCTAssertNil(HostInfoProbe.runCommand("/bin/sleep", ["30"]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }
}
