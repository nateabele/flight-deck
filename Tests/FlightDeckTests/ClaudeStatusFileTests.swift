import XCTest
@testable import FlightDeck

final class ClaudeStatusFileTests: XCTestCase {
    private let sid = UUID(uuidString: "a8cf5a53-1a20-4e2c-b5d1-6fca4e6d73af")!

    private func json(
        pid: Int = 4242,
        status: String = "busy",
        waitingFor: String? = nil,
        startedAt: Double = 1_786_415_100_341
    ) -> Data {
        var obj: [String: Any] = [
            "pid": pid,
            "sessionId": sid.uuidString.lowercased(),
            "status": status,
            "startedAt": startedAt,
            "cwd": "/tmp",
            "procStart": "Mon Aug 10 15:03:38 2026",
            "kind": "interactive",
        ]
        if let waitingFor { obj["waitingFor"] = waitingFor }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testDecodesEachStatus() {
        // "shell" decodes to `.idle` plus `reportsBackgroundWork`, not a fourth activity —
        // see `testShellDecodesAsIdlePlusBackgroundWork` below.
        for (raw, expected): (String, SessionActivity) in [
            ("idle", .idle), ("busy", .busy), ("waiting", .waiting), ("shell", .idle),
        ] {
            let entry = ClaudeStatusFile.decode(json(status: raw), expectedPID: 4242)
            XCTAssertEqual(entry?.activity, expected, "status \(raw)")
        }
    }

    func testDecodesWaitingReason() {
        let entry = ClaudeStatusFile.decode(
            json(status: "waiting", waitingFor: "permission prompt"), expectedPID: 4242
        )
        XCTAssertEqual(entry?.waitingFor, "permission prompt")
    }

    func testDecodesSessionIDAndStartedAt() {
        let entry = ClaudeStatusFile.decode(json(), expectedPID: 4242)
        XCTAssertEqual(entry?.sessionID, sid)
        XCTAssertEqual(entry?.startedAt, 1_786_415_100_341)
    }

    /// Schema drift: a status we do not know must degrade to "no status", never a guess.
    func testUnknownStatusYieldsNil() {
        XCTAssertNil(ClaudeStatusFile.decode(json(status: "compacting"), expectedPID: 4242))
    }

    /// The writer is a non-atomic in-place writeFile, so a reader can catch a torn file.
    func testTornJSONYieldsNil() {
        let torn = Data(#"{"pid":4242,"sessionId":"a8cf5a5"#.utf8)
        XCTAssertNil(ClaudeStatusFile.decode(torn, expectedPID: 4242))
    }

    func testPIDMismatchYieldsNil() {
        XCTAssertNil(ClaudeStatusFile.decode(json(pid: 4242), expectedPID: 9999))
    }

    /// An out-of-range pid must fail closed, not trap. `pid_t` is Int32.
    func testOutOfRangePIDYieldsNil() {
        XCTAssertNil(ClaudeStatusFile.decode(json(pid: 99_999_999_999), expectedPID: 4242))
    }

    func testNonUUIDSessionIDYieldsNil() {
        let obj: [String: Any] = ["pid": 4242, "sessionId": "not-a-uuid", "status": "idle"]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        XCTAssertNil(ClaudeStatusFile.decode(data, expectedPID: 4242))
    }

    func testPIDFromFileName() {
        XCTAssertEqual(ClaudeStatusFile.pid(fromFileName: "75951.json"), 75951)
        XCTAssertNil(ClaudeStatusFile.pid(fromFileName: "notes.json"))
        XCTAssertNil(ClaudeStatusFile.pid(fromFileName: "75951.txt"))
        XCTAssertNil(ClaudeStatusFile.pid(fromFileName: "007.json"))  // non-canonical
    }

    func testDecodeCapturesCwdAndProcStart() {
        let sid = UUID()
        let json = """
        {"pid":42,"sessionId":"\(sid.uuidString.lowercased())","status":"idle",\
        "cwd":"/Users/nate/Projects/flight-deck","procStart":"Mon Aug 10 15:03:38 2026",\
        "startedAt":1786374219307}
        """
        let entry = ClaudeStatusFile.decode(Data(json.utf8), expectedPID: 42)

        XCTAssertEqual(entry?.cwd, "/Users/nate/Projects/flight-deck")
        XCTAssertEqual(entry?.procStart, "Mon Aug 10 15:03:38 2026")
    }

    /// Fails closed, like every other required field: a row we cannot place in a
    /// directory is worse than no row, because the transcript path derived from it
    /// would silently point nowhere.
    func testDecodeRejectsRowMissingCwd() {
        let sid = UUID()
        let json = """
        {"pid":42,"sessionId":"\(sid.uuidString.lowercased())","status":"idle",\
        "procStart":"Mon Aug 10 15:03:38 2026"}
        """
        XCTAssertNil(ClaudeStatusFile.decode(Data(json.utf8), expectedPID: 42))
    }

    func testDecodeRejectsRowMissingProcStart() {
        let sid = UUID()
        let json = """
        {"pid":42,"sessionId":"\(sid.uuidString.lowercased())","status":"idle",\
        "cwd":"/Users/nate"}
        """
        XCTAssertNil(ClaudeStatusFile.decode(Data(json.utf8), expectedPID: 42))
    }

    /// `"shell"` is not a fourth activity. Claude Code writes it as `idle && hasBackgroundTasks`
    /// (`mb = rm === "idle" && db ? "shell" : rm`), so it decodes into both facts, not one.
    func testShellDecodesAsIdlePlusBackgroundWork() throws {
        let json = """
        {"pid":2786,"sessionId":"A4C9067B-9CAF-43CB-8B75-88A145249058",
         "status":"shell","cwd":"/tmp","procStart":"Wed Aug 26 03:26:16 2026","startedAt":1}
        """.data(using: .utf8)!
        let entry = try XCTUnwrap(ClaudeStatusFile.decode(json, expectedPID: 2786))
        XCTAssertEqual(entry.activity, .idle)
        XCTAssertTrue(entry.reportsBackgroundWork)
    }

    /// A plain `idle` reports nothing, which is distinct from reporting absence.
    func testIdleReportsNoBackgroundWork() throws {
        let json = """
        {"pid":2497,"sessionId":"3BF6A1C7-00FC-4ABF-92F5-49163B5B4FAB",
         "status":"idle","cwd":"/tmp","procStart":"Wed Aug 26 03:26:15 2026","startedAt":1}
        """.data(using: .utf8)!
        let entry = try XCTUnwrap(ClaudeStatusFile.decode(json, expectedPID: 2497))
        XCTAssertEqual(entry.activity, .idle)
        XCTAssertFalse(entry.reportsBackgroundWork)
    }

    /// Unchanged: an unrecognised status still fails closed.
    func testUnknownStatusStillDecodesToNil() {
        let json = """
        {"pid":1,"sessionId":"3BF6A1C7-00FC-4ABF-92F5-49163B5B4FAB",
         "status":"teleporting","cwd":"/tmp","procStart":"x","startedAt":1}
        """.data(using: .utf8)!
        XCTAssertNil(ClaudeStatusFile.decode(json, expectedPID: 1))
    }
}
