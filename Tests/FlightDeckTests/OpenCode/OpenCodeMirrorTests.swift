import IntakeKit
import FleetKit
import XCTest
@testable import FlightDeck

final class OpenCodeMirrorTests: XCTestCase {
    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The captured database's `session 8`: a RUN_LS turn whose permission was approved, two
    /// more RUN_LS turns (one Esc-rejected), a question, and an aborted SLOW turn.
    func testTheCapturedSessionMirrorsIntoTimelineItems() throws {
        let database = try OpenCodeFixtures.capturedDatabaseCopy()
        let mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_ef6c9549fffeN3i4Mb4QHBuHGh.jsonl")
        let appended = try OpenCodeMirror.sync(
            sessionID: "ses_ef6c9549fffeN3i4Mb4QHBuHGh", database: database, mirror: mirror
        )
        XCTAssertFalse(appended.isEmpty)
        let items = try lines(mirror).enumerated().flatMap {
            OpenCodeTimelineMapper.items(inLine: $0.element, at: $0.offset)
        }
        XCTAssertTrue(items.contains { $0.kind == .userTurn && $0.body.text == "RUN_LS please" })
        XCTAssertTrue(items.contains { $0.kind == .toolCall && $0.body.tool == "bash" })
        XCTAssertTrue(items.contains { $0.kind == .assistantText && $0.body.text == "Tool finished." })
        // Every tool call in a settled message is closed, so the history alone never reads as
        // an open dialog.
        XCTAssertNil(OpenPrompt.find(in: items, agent: "opencode", activity: "waiting"))
    }

    func testASecondSyncAppendsNothingAndKeepsThePrefix() throws {
        let database = try OpenCodeFixtures.capturedDatabaseCopy()
        let mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_ef6c9549fffeN3i4Mb4QHBuHGh.jsonl")
        try OpenCodeMirror.sync(sessionID: "ses_ef6c9549fffeN3i4Mb4QHBuHGh", database: database, mirror: mirror)
        let before = try Data(contentsOf: mirror)
        XCTAssertEqual(try OpenCodeMirror.sync(sessionID: "ses_ef6c9549fffeN3i4Mb4QHBuHGh",
                                               database: database, mirror: mirror), [])
        XCTAssertEqual(try Data(contentsOf: mirror), before)
    }

    /// The invariant the pager's byte offsets rest on: a message still streaming stops the walk,
    /// so nothing after it can be written ahead of it.
    func testOnlyTheSettledPrefixIsWrittenAndItOnlyGrows() throws {
        let db = try SyntheticOpenCodeDatabase()
        try db.session("ses_s", directory: "/w", title: "t")
        try db.message("msg_a", session: "ses_s", created: 1, data: ["role": "user", "time": ["created": 1]])
        try db.part("prt_a", message: "msg_a", session: "ses_s", data: ["type": "text", "text": "first"])
        try db.message("msg_b", session: "ses_s", created: 2, data: ["role": "assistant", "time": ["created": 2]])
        try db.part("prt_b", message: "msg_b", session: "ses_s", data: ["type": "text", "text": "streaming…"])
        try db.message("msg_c", session: "ses_s", created: 3, data: ["role": "user", "time": ["created": 3]])
        try db.part("prt_c", message: "msg_c", session: "ses_s", data: ["type": "text", "text": "queued"])

        let mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_s.jsonl")
        try OpenCodeMirror.sync(sessionID: "ses_s", database: db.url, mirror: mirror)
        let first = try lines(mirror)
        XCTAssertEqual(first.count, 1, "the queued user message waits behind the streaming one")
        XCTAssertTrue(first[0].contains("first"))

        try db.update(message: "msg_b", data: ["role": "assistant", "time": ["created": 2, "completed": 4]])
        try OpenCodeMirror.sync(sessionID: "ses_s", database: db.url, mirror: mirror)
        let second = try lines(mirror)
        XCTAssertEqual(second.count, 2, "the last user message waits for its reply")
        XCTAssertEqual(second[0], first[0], "an existing line is never rewritten")
        XCTAssertTrue(second[1].contains("streaming…"))

        try db.message("msg_d", session: "ses_s", created: 5, data: ["role": "assistant", "time": ["created": 5]])
        try OpenCodeMirror.sync(sessionID: "ses_s", database: db.url, mirror: mirror)
        let third = try lines(mirror)
        XCTAssertEqual(third.count, 3)
        XCTAssertEqual(Array(third.prefix(2)), second)
        XCTAssertTrue(third[2].contains("queued"))
    }

    /// The live defect this rule exists for: OpenCode writes a user message's row before its
    /// parts, and a mirror that took the row on sight kept `"parts":[]` forever.
    func testAUserMessageWithoutItsPartsYetIsNotWritten() throws {
        let db = try SyntheticOpenCodeDatabase()
        try db.session("ses_u", directory: "/w", title: "t")
        try db.message("msg_a", session: "ses_u", created: 1, data: ["role": "user"])
        let mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_u.jsonl")
        try OpenCodeMirror.sync(sessionID: "ses_u", database: db.url, mirror: mirror)
        XCTAssertEqual(try lines(mirror), [])

        try db.part("prt_a", message: "msg_a", session: "ses_u", data: ["type": "text", "text": "hi there"])
        try db.message("msg_b", session: "ses_u", created: 2, data: ["role": "assistant", "time": ["created": 2]])
        try OpenCodeMirror.sync(sessionID: "ses_u", database: db.url, mirror: mirror)
        let all = try lines(mirror)
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all[0].contains("hi there"))
    }

    func testAnErroredAssistantMessageCountsAsSettled() throws {
        let db = try SyntheticOpenCodeDatabase()
        try db.session("ses_e", directory: "/w", title: "t")
        try db.message("msg_a", session: "ses_e", created: 1, data: [
            "role": "assistant", "time": ["created": 1],
            "error": ["name": "MessageAbortedError", "data": ["message": "Aborted"]],
        ])
        let mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_e.jsonl")
        try OpenCodeMirror.sync(sessionID: "ses_e", database: db.url, mirror: mirror)
        XCTAssertEqual(try lines(mirror).count, 1)
    }

    func testPromptRecordsAreAppendedAndSurviveTheNextSync() throws {
        let db = try SyntheticOpenCodeDatabase()
        try db.session("ses_p", directory: "/w", title: "t")
        try db.message("msg_a", session: "ses_p", created: 1, data: ["role": "user"])
        try db.message("msg_b", session: "ses_p", created: 2, data: ["role": "assistant", "time": ["completed": 3]])
        let mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_p.jsonl")
        try OpenCodeMirror.sync(sessionID: "ses_p", database: db.url, mirror: mirror)
        try OpenCodeMirror.append(#"{"id":"per_1","kind":"permission","type":"prompt.asked"}"#, to: mirror)
        try OpenCodeMirror.sync(sessionID: "ses_p", database: db.url, mirror: mirror)
        let all = try lines(mirror)
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all[2].contains("prompt.asked"))
    }

    func testAHugeToolOutputIsCappedInTheFile() {
        let output = String(repeating: "x", count: OpenCodeMirror.toolOutputLimit + 500)
        let part = OpenCodeMirror.trimmed(part: [
            "type": "tool", "tool": "bash", "callID": "c",
            "state": ["status": "completed", "output": output, "metadata": ["huge": true]],
        ])
        let state = part?["state"] as? [String: Any]
        XCTAssertEqual((state?["output"] as? String)?.utf8.count, OpenCodeMirror.toolOutputLimit)
        XCTAssertEqual(state?["truncated"] as? Int, 500)
        XCTAssertNil(state?["metadata"])
    }

    func testTheDatabaseIsFoundByChannelName() throws {
        let home = OpenCodeFixtures.temporaryDirectory()
        let data = home.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        XCTAssertNil(OpenCodeMirror.databaseURL(home: home))
        FileManager.default.createFile(atPath: data.appendingPathComponent("opencode-dev.db").path, contents: Data())
        XCTAssertEqual(OpenCodeMirror.databaseURL(home: home)?.lastPathComponent, "opencode-dev.db")
        FileManager.default.createFile(atPath: data.appendingPathComponent("opencode.db").path, contents: Data())
        XCTAssertEqual(OpenCodeMirror.databaseURL(home: home)?.lastPathComponent, "opencode.db",
                       "the stable channel's file wins")
    }

    func testTopLevelSessionsExcludeSubagentsAndArchived() throws {
        let db = try SyntheticOpenCodeDatabase()
        try db.session("ses_root", directory: "/w", title: "root")
        try db.session("ses_child", directory: "/w", title: "child", parent: "ses_root")
        try db.session("ses_old", directory: "/w", title: "old", archived: true)
        XCTAssertEqual(try OpenCodeDatabase(url: db.url).topLevelSessions().map(\.id), ["ses_root"])
    }
}
