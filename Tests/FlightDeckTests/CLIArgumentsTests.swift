import FleetKit
import XCTest

final class CLIArgumentsTests: XCTestCase {
    private func parse(_ s: String...) throws -> CLIInvocation { try CLIArguments.parse(s) }

    func testGlobalsAnywhere() throws {
        XCTAssertEqual(try parse("ls", "--json"), CLIInvocation(command: .ls(project: nil), json: true, socket: nil))
        XCTAssertEqual(try parse("--socket", "/s", "ls").socket, "/s")
    }
    func testNoArgumentsIsHelp() throws { XCTAssertEqual(try CLIArguments.parse([]).command, .help) }
    func testTail() throws {
        XCTAssertEqual(try parse("tail", "--session", "self", "--since", "12", "--no-snapshot").command,
                       .tail(session: "self", since: 12, noSnapshot: true))
    }
    func testWaitNeedsFor() {
        XCTAssertThrowsError(try parse("wait", "abcd"))
        XCTAssertEqual(try? parse("wait", "abcd", "--for", "idle", "--timeout", "30").command,
                       .wait(session: "abcd", condition: "idle", timeout: 30))
    }
    func testSendJoinsNothingAndTakesOneText() throws {
        XCTAssertEqual(try parse("send", "self", "hello there").command, .send(session: "self", text: "hello there"))
        XCTAssertThrowsError(try parse("send", "self"))
    }
    func testAnswerForms() throws {
        XCTAssertEqual(try parse("answer", "s", "allow").command, .answer(session: "s", choice: .allow, call: nil))
        XCTAssertEqual(try parse("answer", "s", "[[0,1],[2]]", "--call", "c").command,
                       .answer(session: "s", choice: .selections([[0, 1], [2]]), call: "c"))
        XCTAssertThrowsError(try parse("answer", "s", "[[x]]"))
    }
    func testPlan() throws {
        XCTAssertEqual(try parse("plan", "reject", "s", "--feedback", "no").command,
                       .planResolve(session: "s", approve: false, feedback: "no"))
        XCTAssertEqual(try parse("plan", "annotate", "s", "note", "--block", "3").command,
                       .planAnnotate(session: "s", text: "note", block: 3))
    }
    func testTimelineAnchors() throws {
        XCTAssertEqual(try parse("timeline", "s").command, .timeline(session: "s", anchor: .latest, limit: 40))
        XCTAssertEqual(try parse("timeline", "s", "--before", "900", "--limit", "5").command,
                       .timeline(session: "s", anchor: .before(900), limit: 5))
    }
    func testReopenNeedsAFullUUID() { XCTAssertThrowsError(try parse("reopen", "abcd")) }
    func testUnknownVerbIsAUsageError() {
        XCTAssertThrowsError(try parse("frobnicate")) { XCTAssertTrue(($0 as? CLIUsageError)?.message.contains("frobnicate") == true) }
    }
}
