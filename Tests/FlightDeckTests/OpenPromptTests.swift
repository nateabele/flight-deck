import CryptoKit
import XCTest
@testable import FleetKit

/// The rule both ends run, and the question it produces.
///
/// **This file is the single most load-bearing thing in the feature**, because the Mac and the
/// phone derive the open call independently and a disagreement between them is an answer typed
/// at the wrong dialog. They share this code precisely so they cannot disagree; these tests are
/// what say the shared code is right.
///
/// **Every question fixture here is a capture**, not a hand-written string:
/// `Fixtures/Claude/question-single.captured.jsonl` and `question-multi.captured.jsonl` are the
/// real `AskUserQuestion` `tool_use` records from the two sessions whose screens were captured
/// beside them, off claude 2.1.241. A fixture authored by whoever wrote the parser agrees with
/// the parser by construction and proves nothing about the wire — which is the failure the
/// `*.captured.*` convention exists to prevent. Only the three shapes claude did **not**
/// produce on that day are assembled here, and each says so where it is built.
final class OpenPromptTests: XCTestCase {

    // MARK: Fixtures

    private func call(
        _ id: String, tool: String, kind: TimelineItem.Kind = .toolCall,
        text: String = "{}", summary: String? = nil, offset: Int
    ) -> TimelineItem {
        TimelineItem(
            id: TimelineItem.identifier(offset: offset, index: 0), kind: kind, status: .complete,
            body: .init(text: text, summary: summary, tool: tool, callID: id)
        )
    }

    private func result(_ id: String, offset: Int) -> TimelineItem {
        TimelineItem(
            id: TimelineItem.identifier(offset: offset, index: 0), kind: .toolResult,
            status: .complete, body: .init(text: "done", callID: id)
        )
    }

    private static func capturedLine(_ fixture: String) throws -> String {
        try XCTUnwrap(
            TimelineFixtureTests.lines(fixture, in: "Claude").first, "\(fixture).jsonl is empty"
        )
    }

    /// The `input` object's JSON text, **verbatim** — the bytes claude wrote, in the key order
    /// it wrote them (`question`, `header`, `multiSelect`, `options`), which is neither the
    /// order nor the spacing anything re-serializing through `JSONSerialization` produces. A
    /// truncated body is a prefix of *these* bytes, so a fixture cut anywhere else would be
    /// cutting a document the file never held.
    ///
    /// Sliced by balancing braces from `"input":`, which is sound here and only here: no
    /// description in either capture contains a brace. `JSONSerialization` re-reads the slice
    /// below, so a capture that ever gains one fails loudly rather than silently short.
    private static func capturedInput(_ fixture: String) throws -> String {
        let line = try capturedLine(fixture)
        let start = try XCTUnwrap(
            line.range(of: #""input":"#), "\(fixture).jsonl has no tool input"
        ).upperBound
        var depth = 0
        var index = start
        while index < line.endIndex {
            if line[index] == "{" { depth += 1 }
            if line[index] == "}" {
                depth -= 1
                if depth == 0 {
                    let text = String(line[start...index])
                    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)),
                                     "the brace-balanced slice is not a JSON object")
                    return text
                }
            }
            index = line.index(after: index)
        }
        XCTFail("\(fixture).jsonl's tool input is unbalanced")
        return ""
    }

    /// The `questions` array of a captured record, as values — for the shapes that have to be
    /// assembled out of two captures, and for re-serializing into the bytes the phone gets.
    private static func capturedQuestions(_ fixture: String) throws -> [Any] {
        let line = try capturedLine(fixture)
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let message = try XCTUnwrap(record["message"] as? [String: Any])
        let blocks = try XCTUnwrap(message["content"] as? [[String: Any]])
        let block = try XCTUnwrap(
            blocks.first { $0["name"] as? String == "AskUserQuestion" },
            "\(fixture).jsonl no longer holds an AskUserQuestion tool_use"
        )
        XCTAssertEqual(block["type"] as? String, "tool_use")
        let input = try XCTUnwrap(block["input"] as? [String: Any])
        return try XCTUnwrap(input["questions"] as? [Any])
    }

    private static func serialized(
        _ questions: [Any], _ options: JSONSerialization.WritingOptions = []
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["questions": questions], options: options.union([.sortedKeys])
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// A body cut where the Mac's byte cap would cut it. Four fifths of the single-select
    /// capture keeps the question, the header, the flag and **two whole options**, and loses
    /// the third mid-description — so there is a plausible question in here to salvage, which
    /// is the only reason refusing to salvage it means anything.
    private static func truncatedInput() throws -> String {
        let whole = try capturedInput("question-single.captured")
        return String(whole.prefix(whole.count * 4 / 5))
    }

    // MARK: The rule

    /// **`activity` is not optional and not decorative.** An unanswered call on an idle session
    /// is a call whose RESULT has not been fetched yet — the ordinary state of a feed a beat
    /// behind the file — and offering buttons for it would put a control on a conversation
    /// nobody is blocked on.
    func testAnUnansweredCallOnAnIdleSessionIsNotOpen() {
        let items = [call("toolu_A", tool: "Bash", offset: 0)]
        XCTAssertNil(OpenPrompt.find(in: items, activity: "idle"))
        XCTAssertNil(OpenPrompt.find(in: items, activity: "busy"))
        XCTAssertNil(OpenPrompt.find(in: items, activity: nil))
    }

    func testAnUnansweredToolCallWhileWaitingIsAPermissionRequest() {
        let items = [call("toolu_A", tool: "Bash", summary: "rm -rf build", offset: 0)]
        XCTAssertEqual(
            OpenPrompt.find(in: items, activity: "waiting"),
            .permission(callID: "toolu_A", tool: "Bash", summary: "rm -rf build")
        )
    }

    func testAnUnansweredPromptCallWhileWaitingIsAQuestion() throws {
        let items = [call("toolu_A", tool: "AskUserQuestion", kind: .prompt,
                          text: try Self.capturedInput("question-single.captured"), offset: 0)]
        let open = OpenPrompt.find(in: items, activity: "waiting")
        guard case .question("toolu_A", let question)? = open else {
            return XCTFail("expected a question, got \(String(describing: open))")
        }
        XCTAssertEqual(open?.callID, "toolu_A")
        XCTAssertEqual(question.header, "Language")
        XCTAssertEqual(question.options.count, 3)
    }

    /// **The pairing rule, and the fixture that distinguishes it.** Two calls, the newer one
    /// answered — so a finder that took "the last call" without checking results would return
    /// `toolu_NEW`, and one that stopped at the first unanswered from the front would return
    /// `toolu_OLD` when it should return nothing. The tools differ so the assertion can tell
    /// which mistake was made.
    func testACallWithAResultIsNotOpen() {
        let items = [
            call("toolu_OLD", tool: "Read", offset: 0),
            result("toolu_OLD", offset: 100),
            call("toolu_NEW", tool: "Bash", offset: 200),
            result("toolu_NEW", offset: 300),
        ]
        XCTAssertNil(OpenPrompt.find(in: items, activity: "waiting"))
    }

    /// A result can arrive out of order in a merged feed — `TimelineFeed` orders by byte
    /// offset, but a page boundary can put a result above its call in what the phone holds.
    /// The set of answered ids is therefore built from the WHOLE feed before anything is
    /// judged, not from what follows a given call.
    func testAResultAnywhereInTheFeedClosesItsCall() {
        let items = [
            result("toolu_A", offset: 0),
            call("toolu_A", tool: "Bash", offset: 100),
        ]
        XCTAssertNil(OpenPrompt.find(in: items, activity: "waiting"))
    }

    func testTheNewestUnansweredCallWins() {
        let items = [
            call("toolu_OLD", tool: "Read", offset: 0),
            call("toolu_NEW", tool: "Bash", offset: 100),
        ]
        XCTAssertEqual(
            OpenPrompt.find(in: items, activity: "waiting"),
            .permission(callID: "toolu_NEW", tool: "Bash", summary: nil)
        )
    }

    /// A `.prompt` row whose body the reader truncated is a question this build cannot
    /// reconstruct. It is NOT silently downgraded to a permission card — that would offer
    /// Allow/Deny for a dialog whose first row is "Rust" — and it does NOT fall back to the
    /// older call underneath it, which is not what the terminal is showing. Hence the older
    /// unanswered `Bash` here: it is what a `continue` would wrongly return.
    func testAPromptRowWhoseBodyWillNotParseIsNoOpenPromptAtAll() throws {
        let items = [
            call("toolu_OLD", tool: "Bash", offset: 0),
            call("toolu_A", tool: "AskUserQuestion", kind: .prompt,
                 text: try Self.truncatedInput(), offset: 100),
        ]
        XCTAssertNil(OpenPrompt.find(in: items, activity: "waiting"))
    }

    /// **A row with no `callID` is never an open call, whatever kind it is.** Prose never
    /// carries one; a `.toolCall` can reach the phone without one too, because
    /// `TimelineItem.Body.callID` is optional on the wire and is written only when the agent's
    /// own record held an id. There is nothing to answer with in either case, and falling back
    /// to the row's own `"<offset>#<index>"` id would name a call no agent has — a card the
    /// Mac's re-derivation refuses every time it is tapped, with nothing on screen saying why.
    func testARowWithNoCallIDIsNeverAnOpenCall() {
        let items = [
            call("toolu_A", tool: "Bash", offset: 0),
            TimelineItem(id: "100#0", kind: .toolCall, status: .complete,
                         body: .init(text: "{}", tool: "Write")),
            TimelineItem(id: "200#0", kind: .userTurn, status: .complete, body: .init(text: "hi")),
        ]
        XCTAssertEqual(
            OpenPrompt.find(in: items, activity: "waiting"),
            .permission(callID: "toolu_A", tool: "Bash", summary: nil)
        )
    }

    /// **A kind this build cannot name is not offered a control.** `TimelineItem.Kind` decodes
    /// an unrecognised value as `.unknown` rather than throwing, precisely so a newer Mac can
    /// send a kind an older phone has not heard of — and such a row may well carry a `callID`.
    /// Drawing Allow/Deny for it would be approving something whose meaning this build does
    /// not have. The older `Bash` is what it must find instead.
    func testAKindThisBuildCannotNameIsNotOffered() {
        let items = [
            call("toolu_OLD", tool: "Bash", offset: 0),
            call("toolu_NEW", tool: "Elicit", kind: .unknown, offset: 100),
        ]
        XCTAssertEqual(
            OpenPrompt.find(in: items, activity: "waiting"),
            .permission(callID: "toolu_OLD", tool: "Bash", summary: nil)
        )
    }

    // MARK: The question

    /// The capture, read whole: every label and every description, against the bytes claude
    /// wrote on 2026-08-23.
    func testARealCapturedAskUserQuestionInputParses() throws {
        let question = try XCTUnwrap(
            PromptQuestion(toolInput: try Self.capturedInput("question-single.captured"))
        )
        XCTAssertEqual(question.header, "Language")
        XCTAssertEqual(
            question.question, "Which language would you rather use for a new command line tool?"
        )
        XCTAssertEqual(question.options.map(\.label), ["Rust", "Go", "Swift"])
        XCTAssertEqual(question.options.map(\.detail), [
            "Compiled, memory-safe systems language with no runtime, producing fast single-file "
                + "binaries and a rich CLI ecosystem (clap, anyhow).",
            "Simple, fast-compiling language with a large standard library and effortless "
                + "cross-compilation to static binaries.",
            "Modern, expressive language with strong type safety and first-class Apple platform "
                + "integration, plus ArgumentParser for CLIs.",
        ])
        XCTAssertTrue(question.isAnswerable)
        XCTAssertNil(question.unanswerable)
    }

    /// **One parser, three byte sequences, one question.** The Mac reads a record's own
    /// `input` as the file holds it; the phone reads `TimelineItem.Body.text`, which
    /// `ClaudeTimelineMapper` writes through `ToolInputSummary.pretty` — `.prettyPrinted,
    /// .sortedKeys`, so multi-line, key-reordered and `/`-escaped. Those are different bytes
    /// for the same call, and if they read differently the two ends disagree about the
    /// question while both believing they agree.
    func testTheSameCallReadsTheSameWhicheverEndSerializedIt() throws {
        let questions = try Self.capturedQuestions("question-single.captured")
        let pretty = try Self.serialized(questions, [.prettyPrinted])
        XCTAssertTrue(pretty.contains("\n"), "the mapper pretty-prints; this must not be compact")
        let verbatim = try XCTUnwrap(
            PromptQuestion(toolInput: try Self.capturedInput("question-single.captured"))
        )
        XCTAssertEqual(PromptQuestion(toolInput: pretty), verbatim)
        XCTAssertEqual(PromptQuestion(toolInput: try Self.serialized(questions)), verbatim)
    }

    /// **Carried, drawn, and not answerable.** A multi-select question is answered in the TUI
    /// by toggling rows and then submitting — a second key protocol this build has never
    /// observed and must not guess at. Showing it with an explanation is strictly better than
    /// hiding it: the reader learns there is something waiting and where to go.
    ///
    /// The fixture is a real `multiSelect: true` call, not the single-select one with its flag
    /// flipped.
    func testAMultiSelectQuestionIsCarriedButNotAnswerable() throws {
        let question = try XCTUnwrap(
            PromptQuestion(toolInput: try Self.capturedInput("question-multi.captured"))
        )
        XCTAssertEqual(question.header, "Snacks")
        XCTAssertEqual(question.options.map(\.label),
                       ["Trail mix", "Dark chocolate", "Beef jerky", "Fresh fruit"])
        XCTAssertFalse(question.isAnswerable)
        XCTAssertEqual(question.unanswerable, PromptQuestion.multiSelectReason)
    }

    /// Two real questions in one `questions` array — **assembled**, because no capture has one:
    /// `dialogs.captured.provenance.json` lists "an AskUserQuestion with more than one question"
    /// under `notCaptured`. Both members are captured records; only their juxtaposition is not.
    ///
    /// The multi-select one is put FIRST on purpose, so both reasons apply at once and the
    /// assertion says which wins: several questions is the more surprising fact.
    func testACallCarryingTwoQuestionsIsNotAnswerable() throws {
        let both = try Self.serialized(
            try Self.capturedQuestions("question-multi.captured")
                + Self.capturedQuestions("question-single.captured")
        )
        let question = try XCTUnwrap(PromptQuestion(toolInput: both))
        XCTAssertEqual(question.question, "Which snacks would you want on a long flight?")
        XCTAssertFalse(question.isAnswerable)
        XCTAssertEqual(question.unanswerable, PromptQuestion.multiQuestionReason)
    }

    /// A body cut at `TimelineLimits.maxItemBytes` is the ordinary state of a large tool input,
    /// and **nothing is salvaged from one**. Two of three choices, shown as if they were all
    /// of them, is worse than no card at all: the reader picks the least bad of what they can
    /// see without ever learning what was cut off.
    func testATruncatedInputProducesNoQuestionRatherThanAPartialOne() throws {
        let cut = try Self.truncatedInput()
        XCTAssertTrue(cut.contains(#""question":"Which language"#),
                      "the cut must still carry the question, or it proves nothing")
        XCTAssertTrue(cut.contains(#""label":"Go""#), "and two whole options")
        XCTAssertFalse(cut.hasSuffix("}"), "and must still be structurally incomplete")
        XCTAssertNil(PromptQuestion(toolInput: cut))
    }

    /// Assembled: claude emits no such call, and refusing keeps a malformed record off a
    /// screen that would otherwise draw a question with nothing to tap.
    func testAQuestionWithNoOptionsIsNotAQuestion() {
        XCTAssertNil(PromptQuestion(toolInput: #"{"questions":[{"question":"Well?","options":[]}]}"#))
    }

    /// Assembled, same reason. **An empty string is an absent value, not a present one.** An
    /// option with no label cannot be drawn and cannot be located on the Mac's screen either —
    /// the answer path finds the row BY its label — so carrying it would put an index in the
    /// list that no keystroke can reach. And an empty `header` drawn as a header is a blank
    /// chip above the question, which is worse than no chip — as is an empty `description`
    /// drawn as an option's second line.
    func testAnEmptyLabelHeaderOrDescriptionIsAbsentRatherThanBlank() throws {
        let question = try XCTUnwrap(PromptQuestion(toolInput: """
        {"questions":[{"question":"Well?","header":"","options":[{"label":""},\
        {"label":"Yes","description":""}]}]}
        """))
        XCTAssertEqual(question.options, [PromptQuestion.Option(label: "Yes")])
        XCTAssertNil(question.header)
    }

    /// `init?(toolInput:)` cannot build one, but the memberwise initializer is public and a
    /// card assembled in code can. Nothing with no options is answerable, whatever built it —
    /// a "question" with no buttons is a card whose only honest state is the unanswerable one.
    func testAQuestionBuiltWithNoOptionsIsNotAnswerable() {
        XCTAssertFalse(PromptQuestion(question: "Well?", options: []).isAnswerable)
    }

    // MARK: The fixtures themselves

    /// The whole point of the questions above being captured rather than authored: against the
    /// digest in `dialogs.captured.provenance.json`, because every edit worth worrying about —
    /// a softened description, a flipped `multiSelect` — leaves valid JSON behind.
    func testTheCapturedQuestionRecordsMatchTheirRecordedChecksums() throws {
        let provenance = try TimelineFixtureTests.provenance("dialogs.captured", in: "Claude")
        let recorded = try XCTUnwrap(provenance["sha256"] as? [String: String])
        for name in ["question-single.captured", "question-multi.captured"] {
            let url = try XCTUnwrap(Bundle(for: OpenPromptTests.self).url(
                forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Claude"
            ), "Fixtures/Claude/\(name).jsonl not found in the test bundle")
            let digest = SHA256.hash(data: try Data(contentsOf: url))
            XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(),
                           recorded["\(name).jsonl"],
                           "\(name).jsonl no longer matches the digest in its provenance file — "
                           + "it was edited, or recaptured without updating the provenance")
        }
    }
}
