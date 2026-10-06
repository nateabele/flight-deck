import XCTest
@testable import FlightDeck

@MainActor
final class FlywheelWatcherTests: XCTestCase {
    /// The number of `reads.*` calls one repoll makes. Four lanes are live (`agents`,
    /// `inProgressBeads`, `reservations`, `depEdges`) — `events` is a nil-stub that never
    /// invokes the runner, so a repoll shells out exactly four times.
    let expectedReadsPerPoll = 4

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
        // Priming via `repollNow()` establishes the baseline mtime synchronously (before this
        // call returns), same as `testUnchangedMtimeDoesNotRepoll` — an initial `drain()`
        // instead would itself schedule a spurious repoll (empty cache vs. a real mtime) that
        // only gets cancelled by the real write below landing inside its debounce window, which
        // rode a 20ms-sleep-vs-50ms-debounce margin rather than being structurally guaranteed.
        await w.repollNow()
        try? await Task.sleep(for: .milliseconds(20))
        try? "x".write(to: beads, atomically: true, encoding: .utf8)   // change it
        let before = fake.argv.count
        w.drain(); w.drain(); w.drain()             // a burst
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.argv.count - before, expectedReadsPerPoll,
                       "a burst must coalesce into exactly one repoll")
    }

    /// A `FlywheelProcessRunner` that writes to a watched path the instant its first call
    /// lands and before it returns — simulating a real external mutation racing an in-flight
    /// repoll's subprocess round-trip.
    private final class WriteDuringReadRunner: FlywheelProcessRunner, @unchecked Sendable {
        let watchedPath: URL
        var responses: [String: (String, Int32)] = [:]
        private(set) var argv: [[String]] = []
        private var hasWritten = false

        init(watchedPath: URL) { self.watchedPath = watchedPath }

        func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
            argv.append([exe] + args)
            if !hasWritten {
                hasWritten = true
                // Mutates synchronously, before `run` returns — guarantees this write
                // happens-before the `await` in `repollNow()` completes, so the race is
                // deterministic rather than timing-dependent.
                try? "changed-during-read".write(to: watchedPath, atomically: true, encoding: .utf8)
            }
            let key = ([exe] + args.prefix(2)).joined(separator: " ")
            return responses[key] ?? ("", 127)
        }
    }

    /// Regression for the "Needs fixes" review finding: recording the mtime baseline *after*
    /// the reads land would stat the write below's newer mtime and fold it straight into
    /// "already seen" — dropping the change until some unrelated later write re-trips the
    /// gate. The baseline must be captured before the reads are issued instead, so a write
    /// landing mid-flight leaves a newer mtime than what got cached, and the very next
    /// `drain()` still schedules a follow-up repoll for it.
    func testWriteDuringInFlightReadIsNotDropped() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let beads = dir.appendingPathComponent("beads.db"); FileManager.default.createFile(atPath: beads.path, contents: Data())
        let fake = WriteDuringReadRunner(watchedPath: beads)
        fake.responses["am agents list"] = ("[]", 0)
        let reads = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let w = FlywheelWatcher(project: dir.path, watchPaths: [beads], reads: reads, clock: nil,
                                debounce: .milliseconds(50), onChange: { _ in })

        // The runner mutates `beads` while this read is in flight, before `repollNow()`
        // records its baseline mtime.
        await w.repollNow()
        let before = fake.argv.count

        // The mid-flight write must still show up as a moved mtime here.
        w.drain()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.argv.count - before, expectedReadsPerPoll,
                       "a write that lands during an in-flight repoll must not be silently absorbed into the new baseline")
    }
}
