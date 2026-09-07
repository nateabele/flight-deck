import XCTest
@testable import FlightDeck

final class AgentGroupResolverTests: XCTestCase {
    /// A parent that leads its own group and has one child (which inherits the group):
    /// the resolver must return the parent's pid (== the group id).
    func testResolvesChildProcessGroup() throws {
        // /bin/sh -c 'sleep 30' alone is NOT deterministic here: sh tail-call-optimizes a
        // single simple command by exec'ing directly into it (no fork), so `sh` never gets
        // a child (verified empirically in this harness). Backgrounding forces a real fork
        // (POSIX requires it), and `wait` keeps sh alive as the group leader afterward.
        let parent = try ForkedChild.spawnOwnGroup(command: "/bin/sh", args: ["-c", "sleep 30 & wait"])
        defer { parent.terminate() }
        let resolver = PosixAgentGroupResolver()
        var pgid: pid_t?
        for _ in 0..<100 {           // poll for sh to fork its child, no fixed sleep
            pgid = resolver.agentProcessGroup(daemonPID: parent.pid)
            if pgid != nil { break }
            usleep(20_000)
        }
        XCTAssertEqual(pgid, parent.pid)  // child's pgid == parent pid (group leader)
    }

    /// A freshly spawned leaf process has no children → resolver returns nil.
    func testReturnsNilForLeafWithNoChildren() throws {
        let leaf = try ForkedChild.spawnOwnGroup(command: "/bin/sleep", args: ["30"])
        defer { leaf.terminate() }
        XCTAssertNil(PosixAgentGroupResolver().agentProcessGroup(daemonPID: leaf.pid))
    }

    /// Guard: non-positive daemon pid never resolves (never signal group 0/-1 later).
    func testNonPositiveDaemonPidReturnsNil() {
        let r = PosixAgentGroupResolver()
        XCTAssertNil(r.agentProcessGroup(daemonPID: 0))
        XCTAssertNil(r.agentProcessGroup(daemonPID: -1))
    }
}
