import Darwin
import Foundation
import XCTest

/// Never raises a real termination signal in the test process — `SIGUSR1`/`SIGUSR2` stand in
/// for `SIGTERM`/`SIGINT`/`SIGHUP` via `install(signals:)`'s override, exactly so a bug here
/// can't take `xctest` down with it.
final class RunnerSignalsTests: XCTestCase {
    func testARaisedSignalCancels() async {
        let cancelled = expectation(description: "cancel called")
        let sources = RunnerSignals.install(signals: [SIGUSR1]) { cancelled.fulfill() }
        raise(SIGUSR1)
        await fulfillment(of: [cancelled], timeout: 5)
        withExtendedLifetime(sources) {}
    }

    func testEverySignalInTheListCancelsIndependently() async {
        let cancelled = expectation(description: "cancel called")
        cancelled.expectedFulfillmentCount = 2
        let sources = RunnerSignals.install(signals: [SIGUSR1, SIGUSR2]) { cancelled.fulfill() }
        raise(SIGUSR1)
        raise(SIGUSR2)
        await fulfillment(of: [cancelled], timeout: 5)
        withExtendedLifetime(sources) {}
    }

    /// Without `install` first ignoring the signal, this would be the one thing standing
    /// between a caller and the default action actually killing the process — the property
    /// this whole helper exists to prevent for SIGTERM/SIGINT/SIGHUP in production.
    func testDefaultTerminationSignalsAreTheDocumentedThree() {
        XCTAssertEqual(RunnerSignals.terminationSignals, [SIGTERM, SIGINT, SIGHUP])
    }
}
