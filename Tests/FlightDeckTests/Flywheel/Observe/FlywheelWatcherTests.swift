import XCTest
@testable import FlightDeck

@MainActor
final class FlywheelWatcherTests: XCTestCase {
    /// The number of `reads.*` calls one repoll makes. Task 2 shipped only two live lanes
    /// (`agents`, `inProgressBeads`) — `reservations`/`depEdges`/`events` are nil-stubs that
    /// never invoke the runner, so a repoll shells out exactly twice.
    let expectedReadsPerPoll = 2

    func testUnchangedMtimeDoesNotRepoll() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let beads = dir.appendingPathComponent("beads.db"); FileManager.default.createFile(atPath: beads.path, contents: Data())
        let fake = MultiRunner(); fake.responses["am agents list"] = ("[]", 0)
        let reads = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        var snaps = 0
        let w = FlywheelWatcher(project: dir.path, watchPaths: [beads], reads: reads, clock: nil,
                                onChange: { _ in snaps += 1 })
        await w.repollNow()                 // priming read
        let baseline = fake.argv.count
        w.drain(); w.drain()                // no file change between/after
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.argv.count, baseline, "an unchanged mtime must not shell out again")
    }

    func testChangedMtimeCoalescesToOneRepoll() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let beads = dir.appendingPathComponent("beads.db"); FileManager.default.createFile(atPath: beads.path, contents: Data())
        let fake = MultiRunner(); fake.responses["am agents list"] = ("[]", 0)
        let reads = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let w = FlywheelWatcher(project: dir.path, watchPaths: [beads], reads: reads, clock: nil,
                                debounce: .milliseconds(50), onChange: { _ in })
        w.drain()                                   // establish baseline mtime
        try? await Task.sleep(for: .milliseconds(20))
        try? "x".write(to: beads, atomically: true, encoding: .utf8)   // change it
        let before = fake.argv.count
        w.drain(); w.drain(); w.drain()             // a burst
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.argv.count - before, expectedReadsPerPoll,
                       "a burst must coalesce into exactly one repoll")
    }
}
