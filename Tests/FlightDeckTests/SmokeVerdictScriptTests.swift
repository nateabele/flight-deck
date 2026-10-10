import XCTest

/// `scripts/lib-smoke-verdict.sh`, the verdict `smoke-remote.sh` prints after a successful
/// xcodebuild run. The failure it prevents: gated UI classes skip every case when their
/// TEST_RUNNER_* variable is unset, xcodebuild calls that success, and the run used to end
/// "SMOKE PASS" — a pass that was reported as the Flight Control UI classes passing.
final class SmokeVerdictScriptTests: XCTestCase {
    private static let library = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/lib-smoke-verdict.sh")

    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("smoke verdict \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func line(_ name: String, _ outcome: String) -> String {
        "Test Case '-[FlightDeckUITests.\(name)]' \(outcome) (0.012 seconds)."
    }

    /// Runs the verdict under `set -euo pipefail`, as smoke-remote.sh does, over a log of `lines`.
    private func verdict(_ lines: [String], only: [String]) throws -> (status: Int32, output: String) {
        let log = temp.appendingPathComponent("run.log")
        try (["Command line invocation:", "Test Suite 'Selected tests' started"] + lines + ["** TEST EXECUTE SUCCEEDED **"])
            .joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail; source \"$1\"; shift; smoke_verdict \"$@\"; echo AFTER",
                             "bash", Self.library.path, log.path] + only
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testNamedClassesThatSkippedEveryCaseAreSkippedNotPassed() throws {
        let result = try verdict([line("RoutingUITests testA", "skipped"), line("CapacityUITests testB", "skipped")],
                                 only: ["FlightDeckUITests/RoutingUITests", "FlightDeckUITests/CapacityUITests"])
        XCTAssertEqual(result.status, 5, result.output)
        XCTAssertTrue(result.output.contains("0 passed, 0 failed, 2 skipped"), result.output)
        XCTAssertTrue(result.output.contains("SMOKE SKIPPED"), result.output)
        XCTAssertFalse(result.output.contains("SMOKE PASS"), result.output)
        XCTAssertFalse(result.output.contains("AFTER"), "set -e must stop the caller on SKIPPED")
    }

    func testANamedSelectionThatMatchedNothingIsNotAPass() throws {
        let result = try verdict([], only: ["FlightDeckUITests/NoSuchUITests"])
        XCTAssertEqual(result.status, 5, result.output)
        XCTAssertTrue(result.output.contains("SMOKE SKIPPED"), result.output)
    }

    func testANamedClassThatRanPassesAndReportsItsSkips() throws {
        let result = try verdict([line("RoutingUITests testA", "passed"), line("RoutingUITests testB", "skipped")],
                                 only: ["FlightDeckUITests/RoutingUITests"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("1 passed, 0 failed, 1 skipped"), result.output)
        XCTAssertTrue(result.output.contains("SMOKE PASS"), result.output)
        XCTAssertTrue(result.output.contains("AFTER"))
    }

    /// The default smoke runs the whole bundle, where the gated classes skipping is expected.
    func testTheWholeSuiteSmokeStillPassesWithItsGatedClassesSkipped() throws {
        let result = try verdict([line("TerminalSmokeTests testSmoke", "passed"), line("RoutingUITests testA", "skipped")],
                                 only: ["FlightDeckUITests"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("1 passed, 0 failed, 1 skipped"), result.output)
        XCTAssertTrue(result.output.contains("SMOKE PASS"), result.output)
    }

    func testTheWholeSuiteSmokeKeepsItsPassEvenWhenEverythingSkipped() throws {
        let result = try verdict([line("RoutingUITests testA", "skipped")], only: ["FlightDeckUITests"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("SMOKE PASS"), result.output)
    }
}
