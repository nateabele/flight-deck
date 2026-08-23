import FleetKit
import XCTest
@testable import FlightDeck

/// Claude's half of the one vocabulary (spec §6). Pure, per line, from records whose shapes
/// were read off real transcripts on the build machine.
///
/// Three of these guard a rule whose violation is invisible rather than noisy — an image's
/// base64 going on the wire, a redacted thinking block rendering as a blank row, and a
/// sub-agent record interleaving into the main conversation. Each has a named mutation in
/// Step 4.
///
/// The other standing rule here: **the unit under test is every field of every item emitted**,
/// not the function. A test that checks `kind` and `text` passes with `tool` and `callID`
/// crossed, so each record shape has one test that pins the fields it MUST populate and the
/// fields it must leave alone, at values no two of which are interchangeable.
final class ClaudeTimelineMapperTests: XCTestCase {
    private func items(_ line: String, at offset: Int = 100) -> [TimelineItem] {
        ClaudeTimelineMapper.items(inLine: line, at: offset)
    }

    func testAUserRecordWithStringContentIsOneUserTurn() {
        let items = items("""
            {"type":"user","uuid":"u1","timestamp":"2026-08-21T10:00:00.000Z",\
            "isSidechain":false,"message":{"role":"user","content":"read project.yml"}}
            """)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .userTurn)
        XCTAssertEqual(items[0].body.text, "read project.yml")
        XCTAssertEqual(items[0].id, "100#0")
        XCTAssertEqual(items[0].at, "2026-08-21T10:00:00.000Z")
        XCTAssertEqual(items[0].status, .complete)
    }

    /// A user turn is prose, so every other `Body` field must stay at its default: a `summary`
    /// means "the text is unfit for a row", a `tool`/`callID` means "this row is part of a
    /// tool exchange", and both are lies about a typed prompt.
    func testAUserTurnPopulatesNothingBeyondItsText() {
        let body = items("""
            {"type":"user","uuid":"u1","timestamp":"2026-08-21T10:00:00.000Z",\
            "isSidechain":false,"message":{"role":"user","content":"read project.yml"}}
            """)[0].body
        XCTAssertNil(body.summary)
        XCTAssertNil(body.tool)
        XCTAssertNil(body.callID)
        XCTAssertFalse(body.isError)
        XCTAssertEqual(body.truncatedBytes, 0)
    }

    func testAnAssistantRecordSplitsIntoOneItemPerBlock() {
        let items = items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"thinking","thinking":"weighing it","signature":"CAIS7wYK"},\
            {"type":"text","text":"I'll read the file."},\
            {"type":"tool_use","id":"toolu_01A","name":"Bash",\
            "input":{"command":"sed -n '1,60p' project.yml","description":"Read it"}}]}}
            """)
        XCTAssertEqual(items.map(\.kind), [.thinking, .assistantText, .toolCall])
        XCTAssertEqual(items.map(\.id), ["100#0", "100#1", "100#2"],
                       "the block index is what makes several items from one line addressable")
        XCTAssertEqual(items[2].body.tool, "Bash")
        XCTAssertEqual(items[2].body.callID, "toolu_01A")
        XCTAssertEqual(items[2].body.summary, "sed -n '1,60p' project.yml",
                       "a row cannot render pretty-printed JSON; the command is the preview")
        XCTAssertTrue(items[2].body.text.contains("\"command\""),
                      "the detail screen still gets the whole input")
    }

    /// Assistant prose, like user prose, is the whole of the row. Distinct from the thinking
    /// case below only by `kind`, which is exactly why both are pinned: one `case` arm
    /// returning the other's kind is otherwise a silent relabelling of the agent's reasoning
    /// as its speech.
    func testAnAssistantTextCarriesOnlyItsText() {
        let item = items("""
            {"type":"assistant","uuid":"a1","timestamp":"2026-08-21T11:11:11.000Z",\
            "isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"text","text":"I'll read the file."}]}}
            """, at: 4242)[0]
        XCTAssertEqual(item.kind, .assistantText)
        XCTAssertEqual(item.status, .complete)
        XCTAssertEqual(item.id, "4242#0")
        XCTAssertEqual(item.at, "2026-08-21T11:11:11.000Z")
        XCTAssertEqual(item.body.text, "I'll read the file.")
        XCTAssertNil(item.body.summary)
        XCTAssertNil(item.body.tool)
        XCTAssertNil(item.body.callID)
        XCTAssertFalse(item.body.isError)
        XCTAssertEqual(item.body.truncatedBytes, 0)
    }

    func testAThinkingItemCarriesOnlyItsThinking() {
        let item = items("""
            {"type":"assistant","uuid":"a1","timestamp":"2026-08-21T12:12:12.000Z",\
            "isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"thinking","thinking":"weighing it","signature":"CAIS7wYK"}]}}
            """, at: 909)[0]
        XCTAssertEqual(item.kind, .thinking)
        XCTAssertEqual(item.status, .complete)
        XCTAssertEqual(item.id, "909#0")
        XCTAssertEqual(item.at, "2026-08-21T12:12:12.000Z")
        XCTAssertEqual(item.body.text, "weighing it")
        XCTAssertNil(item.body.summary)
        XCTAssertNil(item.body.tool)
        XCTAssertNil(item.body.callID)
        XCTAssertFalse(item.body.isError)
        XCTAssertEqual(item.body.truncatedBytes, 0)
    }

    /// A `signature` is a several-hundred-byte opaque blob and is not thinking. It must never
    /// reach a phone.
    func testAThinkingBlocksSignatureIsNeverCarried() {
        let items = items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"thinking","thinking":"weighing it","signature":"CAIS7wYKowEIERgC"}]}}
            """)
        XCTAssertEqual(items[0].body.text, "weighing it")
        XCTAssertFalse(items[0].body.text.contains("CAIS"))
    }

    /// A redacted thinking block is `{"thinking":"","signature":"…"}`, and there are hundreds
    /// of them in a long conversation. Emitting them puts an empty row on screen for each.
    func testARedactedThinkingBlockEmitsNothing() {
        XCTAssertTrue(items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"thinking","thinking":"","signature":"CAIS7wYKowEIERgC"}]}}
            """).isEmpty)
    }

    /// A dropped block still spends its index. Renumbering the survivors would make an item's
    /// id depend on which of its siblings happened to be droppable, so the same byte offset
    /// would address different rows before and after a mapping rule changed.
    func testADroppedBlockDoesNotRenumberTheOnesAfterIt() {
        let items = items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"thinking","thinking":"","signature":"CAIS7wYKowEIERgC"},\
            {"type":"text","text":"straight to the point"}]}}
            """)
        XCTAssertEqual(items.map(\.id), ["100#1"])
    }

    func testAToolCallFillsEveryFieldItsRowNeedsAndNoOther() {
        let item = items("""
            {"type":"assistant","uuid":"a1","timestamp":"2026-08-21T13:13:13.000Z",\
            "isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"tool_use","id":"toolu_019Z","name":"Read",\
            "input":{"file_path":"/tmp/one.txt","limit":10}}]}}
            """, at: 512)[0]
        XCTAssertEqual(item.kind, .toolCall)
        XCTAssertEqual(item.status, .complete)
        XCTAssertEqual(item.id, "512#0")
        XCTAssertEqual(item.at, "2026-08-21T13:13:13.000Z")
        XCTAssertEqual(item.body.tool, "Read")
        XCTAssertEqual(item.body.callID, "toolu_019Z")
        XCTAssertEqual(item.body.summary, "/tmp/one.txt")
        XCTAssertEqual(item.body.text, """
            {
              "file_path" : "\\/tmp\\/one.txt",
              "limit" : 10
            }
            """, "the detail screen gets the whole input, pretty-printed and key-sorted")
        XCTAssertFalse(item.body.isError, "a call has not failed; only a result can")
        XCTAssertEqual(item.body.truncatedBytes, 0)
    }

    /// Nothing in a `tool_result` record names the tool it answers — `ClaudeSession.events`
    /// documents the same gap — so `tool` must stay nil rather than be guessed at. `summary`
    /// stays nil too: a result is prose, and its first line is the right row preview.
    func testAToolResultNamesTheCallItAnswersButNotTheTool() {
        let item = items("""
            {"type":"user","uuid":"u2","timestamp":"2026-08-21T14:14:14.000Z",\
            "isSidechain":false,"message":{"role":"user","content":\
            [{"tool_use_id":"toolu_019Z","type":"tool_result","content":"hi\\n"}]}}
            """, at: 1024)[0]
        XCTAssertEqual(item.kind, .toolResult)
        XCTAssertEqual(item.status, .complete)
        XCTAssertEqual(item.id, "1024#0")
        XCTAssertEqual(item.at, "2026-08-21T14:14:14.000Z")
        XCTAssertEqual(item.body.text, "hi\n")
        XCTAssertNil(item.body.tool)
        XCTAssertNil(item.body.summary)
        XCTAssertEqual(item.body.callID, "toolu_019Z")
        XCTAssertFalse(item.body.isError, "a record with no is_error did not fail")
        XCTAssertEqual(item.body.truncatedBytes, 0)
    }

    func testAToolResultCarriesTheCallItAnswers() {
        let items = items("""
            {"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":\
            [{"tool_use_id":"toolu_01A","type":"tool_result","content":"name: FlightDeck\\n",\
            "is_error":false}]}}
            """)
        XCTAssertEqual(items.map(\.kind), [.toolResult])
        XCTAssertEqual(items[0].body.callID, "toolu_01A")
        XCTAssertEqual(items[0].body.text, "name: FlightDeck\n")
        XCTAssertFalse(items[0].body.isError)
    }

    func testAFailedToolResultSaysSo() {
        let items = items("""
            {"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":\
            [{"tool_use_id":"toolu_01A","type":"tool_result","content":"No such file",\
            "is_error":true}]}}
            """)
        XCTAssertTrue(items[0].body.isError)
    }

    /// A tool result's `content` is a String on most tools and a block array on some. Both are
    /// real; a mapper that handles only the first silently drops the second's output.
    func testAToolResultWithBlockContentIsFlattened() {
        let items = items("""
            {"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":\
            [{"tool_use_id":"toolu_01A","type":"tool_result",\
            "content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}]}}
            """)
        XCTAssertEqual(items[0].body.text, "line one\nline two")
    }

    /// **The base64 never leaves the Mac.** A pasted screenshot is roughly a megabyte of it in
    /// one block; a page of forty records containing two of them is a multi-megabyte frame
    /// over a cellular link, to render a picture the phone is not going to draw anyway.
    ///
    /// Both blocks are pinned field by field. These are the only two arms that reach `Body`
    /// from a *block* inside a `user` record, and until this test said so, relabelling either
    /// one `.assistantText` reddened nothing in the suite: the captured transcript's user
    /// records all carry String content, so no other test feeds a user `text` block at all.
    func testAUserTextBlockAndAnImageBlockAreBothUserTurns() {
        let items = items("""
            {"type":"user","uuid":"u2","timestamp":"2026-08-21T15:15:15.000Z",\
            "isSidechain":false,"message":{"role":"user","content":\
            [{"type":"text","text":"[Image #1] look at this"},\
            {"type":"image","source":{"type":"base64","media_type":"image/png",\
            "data":"iVBORw0KGgoAAAANSUhEUgAAA"}}]}}
            """, at: 2048)
        XCTAssertEqual(items.map(\.kind), [.userTurn, .userTurn])
        XCTAssertEqual(items.map(\.status), [.complete, .complete])
        XCTAssertEqual(items.map(\.id), ["2048#0", "2048#1"])
        XCTAssertEqual(items.map(\.at), ["2026-08-21T15:15:15.000Z", "2026-08-21T15:15:15.000Z"])
        XCTAssertEqual(items.map(\.body.text), ["[Image #1] look at this", "[image]"])
        XCTAssertFalse(items.contains { $0.body.text.contains("iVBORw0") })
        for body in items.map(\.body) {
            XCTAssertNil(body.summary)
            XCTAssertNil(body.tool)
            XCTAssertNil(body.callID)
            XCTAssertFalse(body.isError)
            XCTAssertEqual(body.truncatedBytes, 0)
        }
    }

    /// `isMeta` records are claude talking to itself — "Continue from where you left off.",
    /// the image-geometry note. Rendering them as user turns puts words in the user's mouth.
    func testAMetaRecordIsNotAUserTurn() {
        XCTAssertTrue(items("""
            {"type":"user","uuid":"u3","isMeta":true,"isSidechain":false,"message":\
            {"role":"user","content":[{"type":"text","text":"Continue from where you left off."}]}}
            """).isEmpty)
    }

    /// A `/compact` writes its own summary of the conversation so far as a `user` record. It
    /// is claude's prose, several paragraphs of it, and mapping it as a `.userTurn` attributes
    /// all of it to the user — the `isMeta` harm on a record long enough to be believed.
    /// `ConversationTitle.resolve` has skipped this key alongside `isMeta` since the
    /// resumed-conversation work; this mapper inherited only half of that rule.
    func testACompactSummaryIsNotAUserTurn() {
        XCTAssertTrue(items("""
            {"type":"user","uuid":"u4","isCompactSummary":true,"isSidechain":false,\
            "message":{"role":"user","content":"This session is being continued from a \
            previous conversation. The user asked for a pairing code that survives being \
            typed, and I implemented Crockford base32 over 55 bits."}}
            """).isEmpty)
    }

    /// Sub-agent records live in `<conversationId>/subagents/agent-*.jsonl`, which nothing
    /// reads. One appearing in the main transcript means claude changed where it writes them,
    /// and mapping it would interleave a sub-agent's conversation into its parent's.
    func testASidechainRecordIsNotMapped() {
        XCTAssertTrue(items("""
            {"type":"assistant","uuid":"a9","isSidechain":true,"message":{"role":"assistant",\
            "content":[{"type":"text","text":"sub-agent speaking"}]}}
            """).isEmpty)
    }

    func testRecordsThisVocabularyHasNoRowForEmitNothing() {
        for line in [
            // With a `message`, so it reaches the type switch instead of stopping at the
            // `message` guard above it — otherwise the switch's `default` arm, which is the
            // rule this test is named for, has no coverage anywhere in the suite.
            #"{"type":"custom-title","customTitle":"x","sessionId":"s","#
                + #""message":{"role":"user","content":"x"}}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":1}"#,
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"attachment","id":"1"}"#,
            "not json at all",
            "",
        ] {
            XCTAssertTrue(items(line).isEmpty, "\(line.prefix(30)) should map to nothing")
        }
    }

    /// A `user` or `assistant` record whose `message` is missing or is not an object. Nothing
    /// on this machine writes one, which is the point: a malformed line must map to nothing,
    /// the same defensive posture `ClaudeSession.events(inLine:sessionID:)` takes.
    func testAMalformedMessageRecordEmitsNothingRatherThanACrash() {
        for line in [
            #"{"type":"user","uuid":"u1","isSidechain":false}"#,
            #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":"not an object"}"#,
            #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant"}}"#,
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"content":[1,2,3]}}"#,
            #"["not","an","object"]"#,
            #"{"uuid":"no-type"}"#,
        ] {
            XCTAssertTrue(items(line).isEmpty, "\(line.prefix(40)) should map to nothing")
        }
    }

    /// `at` is the record's own timestamp verbatim and nothing else. A record without one is
    /// undated rather than dated now — this mapper never calls `Date()`, so a re-fetch of the
    /// same page cannot come back with a different time on the same row.
    func testARecordWithNoTimestampIsUndated() {
        let items = items("""
            {"type":"user","uuid":"u1","isSidechain":false,\
            "message":{"role":"user","content":"undated"}}
            """)
        XCTAssertNil(items[0].at)
    }

    /// Nothing streams. Both agents are read from files they write, and neither writes token
    /// deltas — see the plan's findings §2. `.streaming` exists in the vocabulary for a future
    /// route; if something starts emitting it, this fails and the UI has to be built for it.
    func testEveryMappedItemIsComplete() {
        let items = items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"t","name":"Bash",\
            "input":{"command":"ls"}}]}}
            """)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.status == .complete })
    }

    // MARK: - A question in the conversation

    /// The captured `AskUserQuestion` records — one line each, lifted whole from the
    /// transcript of the very session whose screen is captured beside them. Written from a
    /// real 2.1.241 session rather than from this mapper's idea of one, because the three
    /// wire-format bugs this project has shipped were each a fixture and a parser agreeing
    /// with the same wrong assumption.
    private func questionLine(_ fixture: String) throws -> String {
        try XCTUnwrap(TimelineFixtureTests.lines(fixture, in: "Claude").first,
                      "\(fixture).jsonl is empty")
    }

    /// The `tool_use` block's `input` as claude wrote it, straight out of the fixture, so a
    /// test can compare what travelled against what was recorded.
    private func toolInput(inLine line: String) throws -> [String: Any] {
        let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let blocks = (record?["message"] as? [String: Any])?["content"] as? [[String: Any]]
        return try XCTUnwrap(blocks?.first?["input"] as? [String: Any])
    }

    /// **`.prompt`, the kind reserved for this since the timeline shipped and emitted by
    /// nothing until now.** It was left alone deliberately: a message a person types is a
    /// `.userTurn`, which both mappers already emit, so the case was free for the one row
    /// that is genuinely a question put to the user. This is that row.
    ///
    /// Everything else about it is a tool call's, and each of those fields is load-bearing
    /// somewhere: the `callID` is what `SessionTimelineScreen.entries(from:)` folds the
    /// answering `tool_result` onto, and the tool name is what a detail screen titles it
    /// with. Only the kind moves.
    func testAnAskUserQuestionIsAPromptRatherThanAToolCall() throws {
        let item = try XCTUnwrap(items(try questionLine("question-single.captured")).first)
        XCTAssertEqual(item.kind, .prompt)
        XCTAssertEqual(item.body.tool, "AskUserQuestion")
        XCTAssertEqual(item.body.callID, "toolu_01AoVBuWGeEn98vozn3y2XH4")
        XCTAssertEqual(item.id, "100#0")
        XCTAssertEqual(item.status, .complete)
        XCTAssertEqual(item.at, "2026-08-23T20:44:19.502Z")
    }

    /// The whole input travels in `text`, unchanged and unabridged, because that string is
    /// the only copy of the question either end has: the phone rebuilds the question, its
    /// header and every option — label and description both — by parsing this field. A
    /// mapping that summarised it here would leave a card with nothing to draw.
    func testAQuestionsWholeInputTravelsInTheRowsText() throws {
        let line = try questionLine("question-single.captured")
        let item = try XCTUnwrap(items(line).first)
        let travelled = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(item.body.text.utf8)) as? [String: Any],
            "the row's text must still parse as the input object it was made from"
        )
        XCTAssertEqual(travelled as NSDictionary, try toolInput(inLine: line) as NSDictionary,
                       "the input claude wrote and the input that travelled must be the same "
                       + "object, options and descriptions included")
        // Named explicitly as well, because a dictionary comparison reports a failure as two
        // walls of JSON and these are the strings a card is built out of.
        XCTAssertTrue(item.body.text.contains(
            "Which language would you rather use for a new command line tool?"))
        for label in ["Rust", "Go", "Swift"] {
            XCTAssertTrue(item.body.text.contains(#""label" : "\#(label)""#),
                          "every option must travel, not just the first")
        }
    }

    /// A one-line preview drawn from the question itself.
    ///
    /// The first assertion is what makes this test able to fail at all: an `AskUserQuestion`
    /// input's only top-level key is `questions`, and `ToolInputSummary`'s table has no entry
    /// that reaches two levels down into `questions[0]` — so the ordinary path finds nothing
    /// and the row would say nothing at all. Both captures, single- and multi-select, because
    /// the two shapes differ on screen and must not differ here.
    func testAPromptRowPreviewsItsQuestion() throws {
        for (fixture, question) in [
            ("question-single.captured",
             "Which language would you rather use for a new command line tool?"),
            ("question-multi.captured", "Which snacks would you want on a long flight?"),
        ] {
            let line = try questionLine(fixture)
            XCTAssertNil(ToolInputSummary.text(for: try toolInput(inLine: line)),
                         "\(fixture) must carry no top-level preview key, or the ordinary "
                         + "table finds one and this test proves nothing")
            XCTAssertEqual(try XCTUnwrap(items(line).first).body.summary, question, fixture)
        }
    }

    /// `summary` escapes every budget downstream — `TimelineReader.capped` rewrites
    /// `body.text` and never touches it — so `ToolInputSummary.maxSummaryBytes` is the only
    /// bound this field gets anywhere, and a preview added on a new path has to go through it
    /// too. Synthetic rather than captured: no captured question is long enough to cut, and
    /// the bound is about a question nobody has asked yet.
    func testALongQuestionsPreviewIsStillBounded() throws {
        let long = String(repeating: "why ", count: 200)
        let item = try XCTUnwrap(items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"tool_use","id":"toolu_A","name":"AskUserQuestion",\
            "input":{"questions":[{"question":"\(long)","header":"H","multiSelect":false,\
            "options":[{"label":"a"}]}]}}]}}
            """).first)
        XCTAssertEqual(item.kind, .prompt)
        XCTAssertEqual(try XCTUnwrap(item.body.summary).utf8.count,
                       ToolInputSummary.maxSummaryBytes)
    }

    /// A shape `AskUserQuestion` never wrote is still a question — the kind is decided by the
    /// tool's name and nothing else — and it previews through the ordinary key table rather
    /// than reaching into an empty array.
    func testAQuestionWithNothingToPreviewIsStillAPrompt() throws {
        let item = try XCTUnwrap(items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"tool_use","id":"toolu_A","name":"AskUserQuestion",\
            "input":{"questions":[]}}]}}
            """).first)
        XCTAssertEqual(item.kind, .prompt)
        XCTAssertNil(item.body.summary)
    }

    /// Every other tool is untouched, because the rule is scoped by the tool's name and by
    /// nothing else. `Bash` from the captured transcript, because a tool call awaiting
    /// permission is read as a permission request rather than as a question, and that reading
    /// is the kind.
    func testEveryOtherToolIsStillAToolCall() throws {
        let line = try XCTUnwrap(
            TimelineFixtureTests.lines("transcript.captured", in: "Claude")
                .first { $0.contains(#""name":"Bash""#) },
            "the capture must still hold the Bash call"
        )
        let item = try XCTUnwrap(items(line).first { $0.body.tool == "Bash" })
        XCTAssertEqual(item.kind, .toolCall)
        XCTAssertEqual(item.body.summary, "echo hi")
    }

    /// The answer stays a `.toolResult`, so it still folds into the question on `callID`
    /// rather than stranding itself as its own row below it. Hand-written, and it is the one
    /// record here that has to be: the captured question lines are the last line of their
    /// transcripts — claude writes the `tool_use` before the tool runs, which is why the
    /// question is readable while it is still open — so no capture holds an answer to one.
    func testTheAnswerToAQuestionIsStillAToolResult() throws {
        let item = try XCTUnwrap(items("""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user",\
            "content":[{"type":"tool_result","tool_use_id":"toolu_01AoVBuWGeEn98vozn3y2XH4",\
            "content":"Your questions have been answered."}]}}
            """).first)
        XCTAssertEqual(item.kind, .toolResult)
        XCTAssertEqual(item.body.callID, "toolu_01AoVBuWGeEn98vozn3y2XH4")
        XCTAssertNil(item.body.tool)
    }
}

/// The preview and detail rendering of a tool's input, which Task 4 shares for codex. Tested
/// directly rather than only through the mapper: the key table is an ordering, and an ordering
/// is exactly the kind of thing a round trip through one example cannot see.
final class ToolInputSummaryTests: XCTestCase {
    func testThePreviewPrefersTheCommandOverTheDescriptionBesideIt() {
        XCTAssertEqual(
            ToolInputSummary.text(for: [
                "description": "Read it", "command": "sed -n '1,60p' project.yml",
            ]),
            "sed -n '1,60p' project.yml",
            "the table is an order of preference, not a search for any String"
        )
    }

    func testThePreviewPrefersTheFilePathOverThePlainPath() {
        XCTAssertEqual(
            ToolInputSummary.text(for: ["path": "/tmp", "file_path": "/tmp/one.txt"]),
            "/tmp/one.txt"
        )
    }

    /// A row is one line high. A heredoc'd `Bash` command is fifty.
    func testThePreviewIsTheFirstLineAlone() {
        XCTAssertEqual(
            ToolInputSummary.text(for: ["command": "  cd /tmp  \necho hi\nexit 0"]),
            "cd /tmp"
        )
    }

    func testAnInputWithNoPreviewableKeyHasNoPreview() {
        XCTAssertNil(ToolInputSummary.text(for: ["todos": ["write it"], "count": 3]))
        XCTAssertNil(ToolInputSummary.text(for: [:]))
        XCTAssertNil(ToolInputSummary.text(for: ["command": "   "]),
                     "whitespace is not a preview")
        XCTAssertNil(ToolInputSummary.text(for: ["command": 7]),
                     "a non-String under a preview key is not a preview")
    }

    /// A row still renders from `Body.tool` when there is no preview, which is why nil is a
    /// legitimate answer rather than a fallback into the pretty-printed JSON.
    func testAToolCallWithNoPreviewableInputStillNamesItsTool() {
        let item = ClaudeTimelineMapper.items(inLine: """
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"tool_use","id":"toolu_01B","name":"TodoWrite",\
            "input":{"todos":[{"content":"ship it","status":"pending"}]}}]}}
            """, at: 0)[0]
        XCTAssertNil(item.body.summary)
        XCTAssertEqual(item.body.tool, "TodoWrite")
        XCTAssertTrue(item.body.text.contains("\"todos\""))
    }

    /// Key order out of `JSONSerialization` is unspecified. Two fetches of one page that
    /// differ only in key order would look to a client like the agent changed its mind.
    /// Six keys, not three, and that is arithmetic rather than taste: Swift seeds `Dictionary`
    /// hashing per process, so an unsorted encoder still emits sorted order by chance with
    /// probability `1/n!`. At three keys that is one run in six — a test that passes 83% of the
    /// time is not a proof. At six it is one in 720.
    func testTheWholeInputIsPrettyPrintedInASortedStableOrder() {
        let pretty = ToolInputSummary.pretty([
            "zebra": 1, "alpha": 2, "middle": 3, "delta": 4, "kilo": 5, "sierra": 6,
        ])
        XCTAssertEqual(pretty, """
            {
              "alpha" : 2,
              "delta" : 4,
              "kilo" : 5,
              "middle" : 3,
              "sierra" : 6,
              "zebra" : 1
            }
            """)
    }

    /// `summary` is the one field that escapes every budget downstream: `TimelineReader` caps
    /// an item by rewriting `body.text` and costs a page by summing `body.text`, so a preview
    /// of any length rides along untouched, 200 items to a page. `prompt` is a preview key and
    /// an `Agent` dispatch's opening paragraph has no newline in it for kilobytes.
    func testALongPreviewIsBoundedEvenWhenItIsAllOneLine() {
        let prompt = String(repeating: "dispatch a sub-agent to do the thing. ", count: 200)
        XCTAssertFalse(prompt.contains("\n"), "the first-line rule bounds nothing here")
        let summary = ToolInputSummary.text(for: ["prompt": prompt])
        XCTAssertEqual(summary?.utf8.count, ToolInputSummary.maxSummaryBytes)
        // ASCII, so a prefix in Characters and a prefix in bytes are the same prefix.
        XCTAssertEqual(summary, String(prompt.prefix(ToolInputSummary.maxSummaryBytes)))
    }

    /// Cutting by bytes must not halve a scalar.
    ///
    /// The single leading ASCII byte is what makes this test able to fail: each ✈︎ here is 4
    /// UTF-8 bytes, and 200 is divisible by 4, so a naive byte-prefix cut of an all-emoji
    /// string lands on a boundary by luck and proves nothing. Offset by one, the 200th byte
    /// falls in the middle of the 50th character, and a byte cut yields a replacement
    /// character where this must yield 197 bytes.
    func testACappedPreviewIsCutOnACharacterBoundary() {
        let long = "x" + String(repeating: "🛩", count: 100)
        let summary = ToolInputSummary.text(for: ["command": long])
        XCTAssertEqual(summary, "x" + String(repeating: "🛩", count: 49),
                       "1 + 49*4 = 197; a 50th would be 201, past the cap")
        XCTAssertEqual(summary?.utf8.count, 197)
        XCTAssertFalse(summary?.contains("\u{FFFD}") == true, "no halved scalar")
    }

    func testAPreviewShorterThanTheCapIsUntouched() {
        XCTAssertEqual(ToolInputSummary.text(for: ["command": "ls -la"]), "ls -la")
    }

    func testAnInputThatIsNotAJSONObjectPrettyPrintsToNothing() {
        XCTAssertEqual(ToolInputSummary.pretty(nil), "")
        XCTAssertEqual(ToolInputSummary.pretty("a bare string"), "")
        XCTAssertEqual(ToolInputSummary.pretty(Date()), "",
                       "a value JSONSerialization would trap on must return empty, not crash")
    }
}
