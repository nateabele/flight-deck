import FleetKit
import XCTest
@testable import FlightDeck

/// The Mac's derivation, and the property that matters most: **it is the phone's derivation.**
/// Both sides map transcript lines with `ClaudeTimelineMapper` and then run
/// `OpenPrompt.find`; nothing here re-implements the pairing rule, and a test that this file
/// agrees with `OpenPromptTests` on the same records is the guard against it drifting.
final class ClaudeOpenCallTests: XCTestCase {
    private func line(_ offset: Int, _ json: String) -> SourceLine {
        SourceLine(offset: offset, text: json)
    }

    private func ask(_ id: String, question: String = "Which?") -> String {
        """
        {"type":"assistant","timestamp":"2026-08-21T04:30:59.425Z","message":{"role":\
        "assistant","content":[{"type":"tool_use","id":"\(id)","name":"AskUserQuestion",\
        "input":{"questions":[{"question":"\(question)","header":"H","multiSelect":false,\
        "options":[{"label":"a","description":"first"},{"label":"b"}]}]}}]}}
        """
    }

    private func bash(_ id: String, command: String = "ls") -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"\(command)"}}]}}
        """
    }

    /// **Hand-written, and it has to be.** No capture holds an answer to a question: claude
    /// writes the call record before the tool runs — which is exactly why a question is
    /// readable while it is still open — and the sessions that produced
    /// `question-*.captured.jsonl` were killed at the dialog. The shape is the one
    /// `ClaudeTimelineMapper` reads for every other tool's result, and
    /// `transcript.captured.jsonl` holds real instances of it.
    private func answer(_ id: String) -> String {
        """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"\(id)","content":"done"}]}}
        """
    }

    func testAnOpenAskIsAQuestion() throws {
        guard case .question("toolu_A", let questions)? =
            ClaudeOpenCall.find(in: [line(0, ask("toolu_A"))], activity: .waiting)
        else { return XCTFail("expected a question") }
        // The payload is the whole set now; these cases each assert one question.
        let question = questions[0]
        XCTAssertEqual(question.question, "Which?")
        XCTAssertEqual(question.options.map(\.label), ["a", "b"])
    }

    func testAnOpenBashIsAPermissionRequest() {
        XCTAssertEqual(
            ClaudeOpenCall.find(in: [line(0, bash("toolu_B", command: "rm -rf build"))],
                                activity: .waiting),
            .permission(callID: "toolu_B", tool: "Bash", summary: "rm -rf build")
        )
    }

    /// The fixture that distinguishes the failure: an answered call and an open one, with
    /// different tools AND different ids, so the assertion catches either mistake.
    func testAnAnsweredCallIsSkippedAndTheOpenOneIsFound() {
        let lines = [
            line(0, ask("toolu_OLD", question: "Old?")),
            line(100, answer("toolu_OLD")),
            line(200, bash("toolu_NEW")),
        ]
        XCTAssertEqual(ClaudeOpenCall.find(in: lines, activity: .waiting)?.callID, "toolu_NEW")
    }

    /// **Newest wins, and no other fixture in this file can say so.** Every other tail here
    /// holds exactly one unanswered call, and `OpenPrompt.find` scans from the end — so
    /// reading those lines in either direction returns the same row, and order is unpinned by
    /// them. Two open calls at once is not hypothetical: a `tool_use` whose result was never
    /// written is what a session killed at its dialog leaves behind, and after a resume the
    /// live dialog sits below it. The terminal is showing the last one, and an answer typed
    /// at the abandoned one goes to whatever is on screen.
    func testTheNewestOfTwoUnansweredCallsWins() {
        let lines = [
            line(0, ask("toolu_ABANDONED", question: "Old?")),
            line(200, bash("toolu_LIVE")),
        ]
        XCTAssertEqual(ClaudeOpenCall.find(in: lines, activity: .waiting),
                       .permission(callID: "toolu_LIVE", tool: "Bash", summary: "ls"))
    }

    /// **The race this derivation exists to close.** A person approves in the terminal, claude
    /// raises the *next* dialog in the same breath, and the session never leaves `waiting` —
    /// so nothing tears down the card the phone is already showing, and a tap on it would
    /// answer a dialog nobody read. The refusal is that the newest open call has MOVED, which
    /// only holds if it is derived again from the file on the answer path: the same question
    /// is asked twice here, `waiting` both times, and the two answers differ. A cached
    /// derivation, or one that stopped at the first unanswered call from the top, returns
    /// `toolu_READ` the second time.
    func testTheOpenCallMovesWhileTheSessionNeverLeavesWaiting() {
        let read = [line(0, ask("toolu_READ", question: "Read?"))]
        XCTAssertEqual(ClaudeOpenCall.find(in: read, activity: .waiting)?.callID, "toolu_READ")

        let unread = read + [line(100, answer("toolu_READ")), line(200, bash("toolu_UNREAD"))]
        let open = ClaudeOpenCall.find(in: unread, activity: .waiting)
        XCTAssertEqual(open, .permission(callID: "toolu_UNREAD", tool: "Bash", summary: "ls"))
        XCTAssertNotEqual(open?.callID, "toolu_READ")
    }

    func testEverythingAnsweredIsNoOpenCall() {
        XCTAssertNil(
            ClaudeOpenCall.find(in: [line(0, ask("toolu_A")), line(100, answer("toolu_A"))],
                                activity: .waiting)
        )
    }

    /// **`activity` is carried through and is not optional.** An unanswered `Bash` on a busy
    /// session is a command that is running, and answering "Allow" at it would press Return
    /// into a live input bar.
    func testAnOpenCallOnANonWaitingSessionIsNotOpen() {
        for activity: SessionActivity? in [.idle, .busy, nil] {
            XCTAssertNil(
                ClaudeOpenCall.find(in: [line(0, bash("toolu_B"))], activity: activity),
                "\(String(describing: activity)) must not produce an open call"
            )
        }
    }

    /// Sidechain records are dropped by the mapper before this sees them, which is the reason
    /// the mapper is in the path rather than a bespoke walker: a sub-agent's question is not
    /// the one the person in front of this tab is being asked, and that rule already exists in
    /// exactly one place.
    func testASidechainQuestionIsNotThisTabsQuestion() {
        let sidechain = ask("toolu_S")
            .replacingOccurrences(of: #""type":"assistant""#,
                                  with: #""type":"assistant","isSidechain":true"#)
        XCTAssertNil(ClaudeOpenCall.find(in: [line(0, sidechain)], activity: .waiting))
    }

    func testAMalformedLineIsSkippedRatherThanFailingTheWholeTail() {
        XCTAssertEqual(
            ClaudeOpenCall.find(in: [line(0, "{not json"), line(20, ask("toolu_A"))],
                                activity: .waiting)?.callID,
            "toolu_A"
        )
    }

    /// A tail read from the middle of a file answers like one read from the start: an
    /// abandoned call, an answered pair and the live one, all at a five-figure base offset.
    ///
    /// **The offsets themselves are read by nothing on this path**, and that was measured
    /// rather than assumed: mapping every line at a constant offset of 0 — which collapses
    /// `TimelineItem.id` to one value for the whole tail — fails no test here, because
    /// `OpenPrompt.find` works from array order and `body.callID` and never consults an id.
    /// So this carries the real offsets because that is what the caller has, and asserts the
    /// thing that IS load-bearing at a non-zero base: order.
    func testATailStartingPartwayThroughAFileStillOrdersCorrectly() {
        let lines = [
            line(90_000, bash("toolu_STALE")),
            line(90_500, ask("toolu_OLD", question: "Old?")),
            line(91_000, answer("toolu_OLD")),
            line(91_500, bash("toolu_NEW", command: "swift build")),
        ]
        XCTAssertEqual(ClaudeOpenCall.find(in: lines, activity: .waiting),
                       .permission(callID: "toolu_NEW", tool: "Bash", summary: "swift build"))
    }

    // MARK: The captured records

    /// The whole path over bytes claude wrote, rather than over a string this file composed:
    /// one real transcript line in, one answerable question out. The hand-written fixtures
    /// above agree with the parser by construction; this is the one that says the two ends
    /// read what claude 2.1.241 actually emits.
    func testACapturedAskUserQuestionIsReadEndToEnd() throws {
        let record = try XCTUnwrap(
            TimelineFixtureTests.lines("question-single.captured", in: "Claude").first,
            "question-single.captured.jsonl is empty"
        )
        guard case .question(let id, let questions)? =
            ClaudeOpenCall.find(in: [line(0, record)], activity: .waiting)
        else { return XCTFail("expected a question") }
        // The payload is the whole set now; these cases each assert one question.
        let question = questions[0]
        XCTAssertEqual(id, "toolu_01AoVBuWGeEn98vozn3y2XH4")
        XCTAssertEqual(question.header, "Language")
        XCTAssertEqual(question.options.map(\.label), ["Rust", "Go", "Swift"])
        XCTAssertNil(question.unanswerable, "one single-select question is answerable")
    }

    /// A captured multi-select call. It is still found — the card has to be able to say why
    /// it cannot be answered from here, which it can only do if the derivation returns it
    /// rather than swallowing it.
    func testACapturedMultiSelectCallIsFoundAndSaysWhyItCannotBeAnswered() throws {
        let record = try XCTUnwrap(
            TimelineFixtureTests.lines("question-multi.captured", in: "Claude").first,
            "question-multi.captured.jsonl is empty"
        )
        guard case .question(_, let questions)? =
            ClaudeOpenCall.find(in: [line(0, record)], activity: .waiting)
        else { return XCTFail("expected a question") }
        // The payload is the whole set now; these cases each assert one question.
        let question = questions[0]
        XCTAssertEqual(question.unanswerable, PromptQuestion.multiSelectReason)
        XCTAssertFalse(question.isAnswerable)
    }
}
