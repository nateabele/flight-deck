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

    /// Same in-memory stand-in `ToolPreferencesTests` and `PreferencesStoreTests` use, so this
    /// test never touches the real defaults domain.
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
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

    func testEnvironmentOverridesWinOverTheLaunchersOwnEnvironment() {
        // `environmentOverrides` is how `ToolRunner.run` applies a session's account — see the
        // comment there for why that happens at the call site rather than inside `environment`.
        // A pane value for the same key must not shadow it.
        let reporter = RecordingReporter()
        let expectation = expectation(description: "reported")
        reporter.onReport = { expectation.fulfill() }

        var launcher = makeLauncher(reporter)
        launcher.environment = { ["CLAUDE_CONFIG_DIR": "/pane/only"] }

        launcher.launch(
            command: "echo $CLAUDE_CONFIG_DIR >&2; exit 1", in: "/tmp", named: "Probe",
            environmentOverrides: ["CLAUDE_CONFIG_DIR": "/work/account"]
        )

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reporter.reports.first?.message, "/work/account")
    }

    // MARK: .configured(_:)

    func testConfiguredHonoursTheShellOverride() {
        // The bug this closes: `ShellToolLauncher()` bare-constructed at both production call
        // sites ignored the Shell & Environment pane entirely. `.configured` is what makes
        // `resolvedShell()` — not `ShellResolver.resolve()`'s environment-only fallback — the
        // thing a tool launch actually asks.
        let preferences = PreferencesStore(persistence: MemoryPersistence())
        preferences.preferences.shell.shellOverride = "/opt/homebrew/bin/fish"

        let launcher = ShellToolLauncher.configured(preferences)

        XCTAssertEqual(launcher.shell(), "/opt/homebrew/bin/fish")
    }

    func testConfiguredMergesThePanesEnvironmentOverProcessEnvironmentWithThePaneWinning() {
        let preferences = PreferencesStore(persistence: MemoryPersistence())
        // PATH is near-certain to already be in ProcessInfo's environment, so overriding it is
        // what proves the pane wins a collision rather than merge() keeping the first value.
        preferences.preferences.shell.environment = [
            "PATH": "/pane/only/bin", "FLIGHT_DECK_TOOL_TEST": "from-pane",
        ]

        let launcher = ShellToolLauncher.configured(preferences)
        let environment = launcher.environment()

        XCTAssertEqual(environment["PATH"], "/pane/only/bin")
        XCTAssertEqual(environment["FLIGHT_DECK_TOOL_TEST"], "from-pane")
        // The process environment must still be the base — an override list is deltas on top
        // of it, not a full replacement, same contract `sessionEnvironment` documents.
        XCTAssertEqual(environment["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    func testConfiguredReadsPreferencesLiveNotAtConstruction() {
        // Captured weakly and re-read on each call, so an edit made in the pane after this
        // launcher was built (e.g. while it sits on `ToolOverlay` across the view's lifetime)
        // still applies to the next launch instead of being frozen at construction.
        let preferences = PreferencesStore(persistence: MemoryPersistence())
        let launcher = ShellToolLauncher.configured(preferences)
        XCTAssertNotEqual(launcher.shell(), "/bin/dash", "no override yet — this would be a false pass")

        preferences.preferences.shell.shellOverride = "/bin/dash"

        XCTAssertEqual(launcher.shell(), "/bin/dash")
    }
}
