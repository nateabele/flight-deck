import XCTest
import IntakeKit
@testable import FlightDeck

/// Re-runs Step 1's probe through the real backend, so a br upgrade that changes ready/scheduler/
/// show/claim shapes fails here instead of in a swarm. Skipped unless `BR_LIVE=1` or
/// `TEST_RUNNER_BR_LIVE=1`, and when br is not at ~/.local/bin/br.
@MainActor
final class BrSwarmLiveTests: XCTestCase {
    func testClaimRaceAndReadyJoinAgainstRealBr() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BR_LIVE"] == "1" || env["TEST_RUNNER_BR_LIVE"] == "1" else { throw XCTSkip("set BR_LIVE=1") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let br = home.appendingPathComponent(".local/bin/br").path
        guard FileManager.default.isExecutableFile(atPath: br) else { throw XCTSkip("br not at ~/.local/bin/br") }
        let dir = home.appendingPathComponent(".fd-l3s-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SystemFlywheelProcessRunner()
        _ = try await runner.run("/usr/bin/git", ["init", "-q"], cwd: dir.path)
        _ = try await runner.run(br, ["init", "--prefix", "live"], cwd: dir.path)
        let id = try await runner.run(br, ["create", "live task", "-t", "task", "--silent"], cwd: dir.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = BrSwarmBackend(runner: runner, brPath: br)
        let ready = try await backend.readyTasks(project: dir).get()
        XCTAssertEqual(ready.map(\.id), [id])
        let first = await backend.claim(id, actor: "LiveOne", project: dir)
        XCTAssertEqual(first, .claimed)
        let second = await backend.claim(id, actor: "LiveTwo", project: dir)
        XCTAssertNotEqual(second, .claimed, "br's claim must be atomic")
        let status = await backend.status(id, project: dir)
        XCTAssertEqual(status, TaskStatusReading(status: "in_progress", assignee: "LiveOne"))
        let reopened = await backend.returnToOpen(id, project: dir)
        XCTAssertTrue(reopened)
        let after = await backend.status(id, project: dir)
        XCTAssertEqual(after?.status, "open")
        XCTAssertNil(after?.assignee)
    }
}
