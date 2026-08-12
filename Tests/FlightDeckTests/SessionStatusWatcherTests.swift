import XCTest
@testable import FlightDeck

@MainActor
final class SessionStatusWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(pid: Int, sid: UUID, status: String,
                       waitingFor: String? = nil, startedAt: Double = 1000,
                       cwd: String = "/tmp",
                       procStart: String = "Mon Aug 10 15:03:38 2026") throws {
        var obj: [String: Any] = [
            "pid": pid, "sessionId": sid.uuidString.lowercased(),
            "status": status, "startedAt": startedAt,
            "cwd": cwd, "procStart": procStart,
        ]
        if let waitingFor { obj["waitingFor"] = waitingFor }
        try JSONSerialization.data(withJSONObject: obj)
            .write(to: dir.appendingPathComponent("\(pid).json"))
    }

    /// Every process is alive unless a test says otherwise.
    private func watcher(
        alive: @escaping (pid_t) -> Bool = { _ in true },
        onChange: @escaping ([pid_t: ClaudeStatusFile.Entry]) -> Void
    ) -> SessionStatusWatcher {
        SessionStatusWatcher(root: dir, isAlive: alive, onChange: onChange)
    }

    func testMapsFileToSessionID() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "waiting", waitingFor: "permission prompt")

        var seen: [pid_t: ClaudeStatusFile.Entry] = [:]
        watcher { seen = $0 }.drain()

        XCTAssertEqual(seen[100]?.activity, .waiting)
        XCTAssertEqual(seen[100]?.waitingFor, "permission prompt")
    }

    func testPicksUpStatusChangeOnSecondDrain() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy")

        var seen: [pid_t: ClaudeStatusFile.Entry] = [:]
        let w = watcher { seen = $0 }
        w.drain()
        XCTAssertEqual(seen[100]?.activity, .busy)

        try write(pid: 100, sid: sid, status: "idle")
        w.drain()
        XCTAssertEqual(seen[100]?.activity, .idle)
    }

    /// `claude` unlinks its file only on a clean exit, so a crash leaks one.
    func testSkipsDeadProcesses() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy")

        var seen: [pid_t: ClaudeStatusFile.Entry] = [:]
        watcher(alive: { _ in false }) { seen = $0 }.drain()

        XCTAssertTrue(seen.isEmpty)
    }

    /// A torn read must not look like "session gone" — the last good status stands.
    func testTornFileKeepsLastKnownStatus() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy")

        var seen: [pid_t: ClaudeStatusFile.Entry] = [:]
        let w = watcher { seen = $0 }
        w.drain()

        // Truncate mid-object, exactly as an in-place rewrite can be observed.
        try Data(#"{"pid":100,"sessi"#.utf8)
            .write(to: dir.appendingPathComponent("100.json"))
        w.drain()

        XCTAssertEqual(seen[100]?.activity, .busy)
    }

    func testRemovedFileDropsSession() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy")

        var seen: [pid_t: ClaudeStatusFile.Entry] = [:]
        let w = watcher { seen = $0 }
        w.drain()

        try FileManager.default.removeItem(at: dir.appendingPathComponent("100.json"))
        w.drain()

        XCTAssertTrue(seen.isEmpty)
    }

    func testIgnoresNonPIDFiles() throws {
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notes.json"))

        var called = false
        watcher { _ in called = true }.drain()

        XCTAssertTrue(called, "drain still reports an empty map")
    }

    func testMissingRootIsNotAnError() {
        let missing = dir.appendingPathComponent("nope", isDirectory: true)
        var seen: [pid_t: ClaudeStatusFile.Entry] = [:]
        SessionStatusWatcher(root: missing, isAlive: { _ in true }) { seen = $0 }.drain()
        XCTAssertTrue(seen.isEmpty)
    }

    func testReportsRowsKeyedByPID() throws {
        let sid = UUID()
        try write(pid: 4242, sid: sid, status: "busy")

        var reported: [pid_t: ClaudeStatusFile.Entry] = [:]
        watcher { reported = $0 }.drain()

        XCTAssertEqual(reported[4242]?.sessionID, sid)
    }

    /// Two processes on one conversation used to collapse into one row, keeping only the
    /// newest `startedAt`. Both are real and both must survive.
    func testTwoProcessesOnOneConversationAreBothReported() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy", startedAt: 1)
        try write(pid: 200, sid: sid, status: "waiting", startedAt: 2)

        var reported: [pid_t: ClaudeStatusFile.Entry] = [:]
        watcher { reported = $0 }.drain()

        XCTAssertEqual(reported.count, 2)
        XCTAssertEqual(reported[100]?.activity, .busy)
        XCTAssertEqual(reported[200]?.activity, .waiting)
    }
}
