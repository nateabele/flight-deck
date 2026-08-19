import XCTest
@testable import FlightDeck

@MainActor
final class ToolLauncherTests: XCTestCase {
    private final class RecordingReporter: ToolLaunchFailureReporting {
        var reports: [(tool: String, message: String)] = []
        var onReport: (() -> Void)?
        func report(tool: String, message: String) {
            reports.append((tool, message))
            onReport?()
        }
    }

    private func makeLauncher(_ reporter: RecordingReporter) -> ShellToolLauncher {
        var launcher = ShellToolLauncher()
        launcher.shell = { "/bin/sh" }
        launcher.environment = { ["PATH": "/usr/bin:/bin"] }
        launcher.reporter = reporter
        launcher.grace = .milliseconds(1500)
        return launcher
    }

    func testANonZeroExitIsReportedWithItsStderr() {
        // The failure this exists for: $EDITOR unset means the shell runs a bare path, gets
        // "permission denied", and — with stderr discarded — ⌘O does nothing at all.
        let reporter = RecordingReporter()
        let expectation = expectation(description: "reported")
        reporter.onReport = { expectation.fulfill() }

        makeLauncher(reporter).launch(
            command: "echo 'no such editor' >&2; exit 3", in: "/tmp", named: "Editor"
        )

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reporter.reports.first?.tool, "Editor")
        XCTAssertTrue(
            reporter.reports.first?.message.contains("no such editor") ?? false,
            "the report must carry what the shell actually said"
        )
    }

    func testACleanExitIsNotReported() {
        let reporter = RecordingReporter()
        makeLauncher(reporter).launch(command: "exit 0", in: "/tmp", named: "Terminal")

        // Outlive the grace window before asserting silence.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(reporter.reports.isEmpty)
    }

    func testAToolStillRunningAfterTheGraceWindowIsNotReported() {
        // A GUI editor stays alive. Waiting for it would mean never reporting anything, and
        // treating "still running" as failure would mean reporting everything.
        let reporter = RecordingReporter()
        makeLauncher(reporter).launch(command: "sleep 30", in: "/tmp", named: "Editor")

        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(reporter.reports.isEmpty)
    }

    func testAnUnlaunchableShellIsReportedImmediately() {
        let reporter = RecordingReporter()
        var launcher = makeLauncher(reporter)
        launcher.shell = { "/nonexistent/shell" }
        let expectation = expectation(description: "reported")
        reporter.onReport = { expectation.fulfill() }

        launcher.launch(command: "true", in: "/tmp", named: "Editor")

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reporter.reports.first?.tool, "Editor")
    }

    func testAFailureAfterFillingTheStderrPipeIsStillReported() {
        // A Pipe's kernel buffer is 64 KiB. Without continuous draining, a child that writes
        // more than that blocks inside `write()` — and a process blocked in a syscall still
        // reports `isRunning == true`, so a verbose failure would look identical to success.
        let reporter = RecordingReporter()
        let expectation = expectation(description: "reported")
        reporter.onReport = { expectation.fulfill() }

        makeLauncher(reporter).launch(
            command: "{ yes | head -c 200000; } >&2; exit 3", in: "/tmp", named: "Editor"
        )

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reporter.reports.first?.tool, "Editor")
        XCTAssertFalse(
            reporter.reports.first?.message.isEmpty ?? true,
            "a verbose failure must still surface some stderr, not be swallowed as success"
        )
    }

    func testTheCommandRunsInTheGivenDirectory() {
        let reporter = RecordingReporter()
        let expectation = expectation(description: "reported")
        reporter.onReport = { expectation.fulfill() }

        // `pwd` to stderr, then fail, so the assertion can read it back through the reporter.
        makeLauncher(reporter).launch(command: "pwd >&2; exit 1", in: "/tmp", named: "Probe")

        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(
            reporter.reports.first?.message.contains("tmp") ?? false,
            "currentDirectoryURL is what makes relative paths in a template resolve"
        )
    }
}
