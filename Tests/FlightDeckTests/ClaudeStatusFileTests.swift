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
        for (raw, expected): (String, SessionActivity) in [
            ("idle", .idle), ("busy", .busy), ("waiting", .waiting), ("shell", .shell),
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
}
