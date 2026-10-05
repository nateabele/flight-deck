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

    /// A child that ignores SIGTERM, whose grandchild also holds the stdout pipe, must still
    /// not pin the call: SIGKILL after the grace, and no waiting on the pipe's far end.
    func testRunCommandSurvivesSigtermTrapAndPipeHoldingGrandchild() {
        let start = Date()
        XCTAssertNil(HostInfoProbe.runCommand("/bin/sh", ["-c", "trap '' TERM; sleep 30"]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    /// `host.info` and every `port.check` shell out through this. A read end left open per
    /// call walks a long-lived hostd (soft limit 256) into EMFILE, and Linux corelibs'
    /// `Process.run` segfaults walking a large `/proc/self/fd`.
    func testRunCommandLeavesOpenFdCountFlat() {
        func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        _ = HostInfoProbe.runCommand("/bin/echo", ["warm"])
        let before = openFDs()
        for _ in 0..<50 { XCTAssertEqual(HostInfoProbe.runCommand("/bin/echo", ["hi"]), "hi") }
        // The common case on a host without Docker: the probe tries three install paths.
        for _ in 0..<50 { XCTAssertNil(HostInfoProbe.runCommand("/nonexistent/docker", ["version"])) }
        XCTAssertLessThanOrEqual(openFDs(), before + 2, "fds before \(before), after \(openFDs())")
    }
}
