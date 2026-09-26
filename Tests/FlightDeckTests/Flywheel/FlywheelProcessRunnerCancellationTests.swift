import XCTest
@testable import FlightDeck

/// Proves `SystemFlywheelProcessRunner.run` is cancellation-aware: a genuinely hung child
/// process (`sleep 30`) must not wedge the caller past the enclosing `Task`'s cancellation,
/// the way `SessionStore.bootFlywheelIdentityIfNeeded`'s timeout race cancels its boot child.
/// Without `withTaskCancellationHandler` terminating the process, this test would block for
/// the full 30s (or hang the suite, since nothing else reaps the child).
final class FlywheelProcessRunnerCancellationTests: XCTestCase {
    func testCancellationTerminatesHungProcessInsteadOfWaitingItOut() async throws {
        let runner = SystemFlywheelProcessRunner()

        let task = Task {
            try await runner.run("/bin/sh", ["-c", "sleep 30"], cwd: nil)
        }

        // Give the child a moment to actually spawn before cancelling, so this exercises a
        // real in-flight `waitUntilExit()` rather than winning a race against `process.run()`.
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        let start = Date()
        do {
            _ = try await task.value
            XCTFail("expected cancellation to surface as an error, not a bogus success")
        } catch {
            // Any error is acceptable here — the load-bearing assertion is the elapsed time
            // below, which proves the 30s sleep was actually interrupted rather than awaited.
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3, "cancellation should terminate the child almost immediately, not wait out its 30s sleep")
    }
}
