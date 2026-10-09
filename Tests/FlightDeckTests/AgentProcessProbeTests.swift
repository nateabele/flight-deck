import XCTest
import IntakeKit
@testable import FlightDeck

/// The liveness a tab's pool lease follows. Driven against real child processes, because the
/// two facts that matter are the kernel's: argv[0] (not the versioned executable name) is what
/// identifies an agent, and a SIGSTOP'd process is still running.
final class AgentProcessProbeTests: XCTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for child in children where child.isRunning {
            kill(child.processIdentifier, SIGCONT)
            child.terminate()
        }
        children.removeAll()
    }

    /// `exec -a <name>` sets argv[0] without a binary of that name, which is exactly how a
    /// versioned claude looks: its file is `2.1.293`, its argv[0] is `claude`.
    private func spawn(argv0: String) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = ["-c", "exec -a \(argv0) /bin/sleep 30"]
        try child.run()
        children.append(child)
        // Wait for the exec to land, so argv[0] is the new one.
        let deadline = Date().addingTimeInterval(5)
        while ProcessArguments.argv0(of: child.processIdentifier) != argv0, Date() < deadline { usleep(20_000) }
        return child
    }

    func testArgvZeroIsWhatTheShellRanNotTheExecutableName() throws {
        let child = try spawn(argv0: "claude")
        XCTAssertEqual(ProcessArguments.argv0(of: child.processIdentifier), "claude")
    }

    func testAnAgentIsFoundByItsProfilesBinaryNameUnderTheRoot() throws {
        _ = try spawn(argv0: "codex")
        let probe = AgentProcessProbe()
        XCTAssertTrue(probe.isRunning(.codex, under: [getpid()]))
        XCTAssertFalse(probe.isRunning(.grok, under: [getpid()]), "another agent's binary is not this agent")
        XCTAssertFalse(probe.isRunning(.codex, under: []), "no root, nothing to find")
    }

    /// Ruling: smart sleep SIGSTOPs an idle agent and keeps the process, so it keeps its lease.
    func testASleepingAgentStillReadsRunning() throws {
        let child = try spawn(argv0: "agy")
        kill(child.processIdentifier, SIGSTOP)
        XCTAssertTrue(AgentProcessProbe().isRunning(.gemini, under: [getpid()]))
    }

    func testAnExitedAgentReadsGone() throws {
        let child = try spawn(argv0: "grok")
        child.terminate()
        child.waitUntilExit()
        XCTAssertFalse(AgentProcessProbe().isRunning(.grok, under: [getpid()]))
    }
}
