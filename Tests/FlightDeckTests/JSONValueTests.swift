import FleetKit
import XCTest

/// The JSON model the phone's tool-body tree is drawn from: what parses, what does not, what
/// order it comes out in, and what a document flattens to.
///
/// It runs on macOS because `JSONValue` is in `FleetKit` and `FleetKit` is where both platforms
/// meet — the same justification `TimelineFeed` and `PromptOutbox` have. Nothing here touches
/// SwiftUI; the phone's side of this (which bodies are *offered* as a tree, and what VoiceOver
/// hears) is in `FlightDeckMobileTests/JSONTreeTests`.
///
/// **Every fixture is a real record**, taken from `AskUserQuestion` calls in
/// `~/.claude/projects/-Users-nate/8261151b-…jsonl`. That tool's input is the shape this whole
/// feature exists for: object → array → object → array → object, with three-hundred-character
/// strings at the leaves.
final class JSONValueTests: XCTestCase {

    // MARK: Order

    /// **The reason this type exists rather than `JSONSerialization`.** That API hands back a
    /// `[String: Any]`, and a Swift `Dictionary` has no order — so the tree and the raw text
    /// beside it would disagree about the same document, differently on each launch.
    ///
    /// Both orders are real and both arrive. The Mac pretty-prints a tool CALL with
    /// `.sortedKeys` (`ClaudeTimelineMapper.pretty`), so `header` reaches the phone first; the
    /// agent's own record has `question` first, which is the order a tool RESULT carrying JSON
    /// arrives in. One document, two orders, and the parser must obey whichever it was handed.
    func testKeysComeOutInTheOrderTheTextWroteThemIn() {
        let sent = keys(of: Self.execModelAsSent)
        let written = keys(of: Self.execModelInDocumentOrder)

        XCTAssertEqual(sent, ["header", "multiSelect", "options", "question"])
        XCTAssertEqual(written, ["question", "header", "multiSelect", "options"])
        XCTAssertNotEqual(sent, written, "two orders of one document must not collapse into one")
    }

    /// A key repeated in one object is legal JSON, and both members have to survive — with
    /// their own row ids. A path built out of key NAMES gives the two the same id, and two rows
    /// sharing an id in a `ForEach` is a diffing bug that shows up as a row that will not open.
    func testARepeatedKeyKeepsBothMembersAndGivesThemDistinctIdentities() {
        guard let document = JSONValue.document(from: #"{"note":"first","note":"second"}"#)
        else { return XCTFail("a repeated key is legal JSON") }

        let rows = document.treeRows(expanded: [])
        XCTAssertEqual(rows.count, 2)
        guard rows.count == 2 else { return }
        XCTAssertEqual(rows.map(\.key), ["note", "note"])
        XCTAssertNotEqual(rows[0].id, rows[1].id, "two rows with one id is a ForEach bug")
        XCTAssertEqual(rows[0].value, .string("first"))
        XCTAssertEqual(rows[1].value, .string("second"))
    }

    // MARK: Numbers

    /// Kept as the lexeme, never round-tripped through `Double`. `1.50` is how a document said
    /// it, `1e3` is not `1000`, and an id past 2^53 does not survive a binary float at all — a
    /// viewer's only job with a number is to show the number that is there.
    func testANumberIsShownWithTheDigitsItWasWrittenWith() {
        let text = #"{"price":1.50,"scale":1e3,"id":9007199254740993,"below":-0.0}"#
        guard let document = JSONValue.document(from: text) else { return XCTFail("valid JSON") }

        XCTAssertEqual(
            document.treeRows(expanded: []).map(\.value),
            [.number("1.50"), .number("1e3"), .number("9007199254740993"), .number("-0.0")]
        )
    }

    // MARK: What must not parse

    /// **The case this whole feature had to be built around.** The Mac cuts an oversized body
    /// at `TimelineLimits.maxItemBytes` wherever that lands, so a big tool input arrives
    /// structurally incomplete *by design* (see `TimelineItem.Body.text`). Every prefix of a
    /// real one must be refused, because half-reading it would draw a confident, wrong picture
    /// of what the tool was asked to do — and the fallback, the raw text, is a good outcome.
    func testEveryPrefixOfARealBodyIsRefusedRatherThanHalfRead() {
        let whole = Self.execModelAsSent
        XCTAssertNotNil(JSONValue.document(from: whole), "the whole body must parse")

        let bytes = Array(whole.utf8)
        for cut in stride(from: 1, to: bytes.count, by: 7) {
            let fragment = String(decoding: bytes[0..<cut], as: UTF8.self)
            XCTAssertNil(
                JSONValue.document(from: fragment),
                "a body cut at \(cut) of \(bytes.count) bytes must fall back to its text"
            )
        }
    }

    /// A bare scalar is legal JSON and is still not a document. A tool result whose whole text
    /// is `42` or `done` would otherwise become a one-node tree — strictly worse than the two
    /// characters it replaced, and a toggle offered for nothing.
    func testABareScalarParsesButIsNotADocument() {
        for text in ["42", #""done""#, "true", "null"] {
            XCTAssertNotNil(JSONValue.parse(text), "\(text) is legal JSON")
            XCTAssertNil(JSONValue.document(from: text), "\(text) has no structure to draw")
        }
    }

    /// Malformed input returns `nil`. It must never trap: these are bytes off a wire, and a
    /// viewer that dies on one is worse than the plain text it replaced.
    func testMalformedInputIsRefusedRatherThanTrapping() {
        let refused = [
            "", "   ", "{", "[1,2", #"{"a":}"#, #"{"a" 1}"#, #"{"a":1,}"#, "[,]",
            // Cut at a MEMBER boundary, with every brace still open. The likeliest shape a
            // small truncated body takes, and the one a parser that "just returns what it has
            // so far" at end of input reads as a complete document.
            #"{"a":1"#, #"{"a":1,"b":2"#, #"{"a":{"b":1}"#,
            #"{'a':1}"#,                 // single quotes are JavaScript, not JSON
            #"{"a":01}"#,                // a leading zero
            #"{"a":.5}"#,                // no integer part
            #"{"a":1.}"#,                // no fraction after the point
            #"{"a":+1}"#,                // a leading plus
            #"{"a":1e}"#,                // no exponent digits
            #"{"a":NaN}"#,
            #"{"a":"unterminated}"#,
            #"{"a":"\q"}"#,              // not one of the six escapes
            #"{"a":"\uD83D"}"#,          // a high surrogate with no low one
            #"{"a":"\uZZZZ"}"#,
            #"{"a":1} trailing"#,        // content after the value
            "[1,2][3]",
        ]
        for text in refused {
            XCTAssertNil(JSONValue.parse(text), "must refuse: \(text)")
        }
    }

    /// A literal tab or newline inside a string is a control character JSON requires to be
    /// escaped, and accepting one means accepting text that is not the document it claims to
    /// be. The escaped spellings are the ones that work.
    func testAnUnescapedControlCharacterInsideAStringIsRefused() {
        XCTAssertNil(JSONValue.parse("{\"a\":\"two\nlines\"}"))
        XCTAssertEqual(
            JSONValue.parse(#"{"a":"two\nlines"}"#),
            .object([.init(key: "a", value: .string("two\nlines"))])
        )
    }

    /// The parser recurses, so nesting is bounded — otherwise a body of a hundred thousand
    /// open brackets is a stack overflow rather than a parse failure, and a crash is not a
    /// fallback. The bound is stated in the call so this can be shown rather than argued.
    func testNestingPastTheGuardIsRefusedRatherThanOverflowingTheStack() {
        func nested(_ depth: Int) -> String {
            String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        }

        XCTAssertNotNil(JSONValue.parse(nested(4), maxDepth: 4), "at the bound, and legal")
        XCTAssertNil(JSONValue.parse(nested(6), maxDepth: 4), "past the bound")
        // The real thing: deep enough to smash the stack if nothing stopped it.
        XCTAssertNil(JSONValue.parse(nested(100_000)))
    }

    // MARK: Strings

    /// Escapes are resolved, including the surrogate PAIR that is how JSON spells every emoji
    /// and every character past the basic plane. A parser that treats the two halves
    /// separately produces two replacement characters where the document had one arrow.
    func testEscapesAreResolvedIncludingSurrogatePairs() {
        let text = #"{"a":"tab\there \u2192 \uD83D\uDE80 \"quoted\" \\ \/"}"#
        guard let document = JSONValue.parse(text) else { return XCTFail("valid JSON") }

        XCTAssertEqual(
            document,
            .object([.init(key: "a", value: .string("tab\there → 🚀 \"quoted\" \\ /"))])
        )
    }

    // MARK: The flattened tree

    /// The shape a real `AskUserQuestion` opens on, row for row.
    ///
    /// Two levels and then stop: the reader sees the question, its header and its flag, with
    /// `options` collapsed beside them saying how many there are. That is the summary someone
    /// wants before deciding to go in — and it is a decision, so it is asserted here rather
    /// than left inside a `DisclosureGroup` where nothing can see it.
    func testARealAskUserQuestionOpensOnTwoLevelsWithItsOptionsStillCollapsed() {
        guard let document = JSONValue.document(from: Self.execModelInDocumentOrder)
        else { return XCTFail("the fixture must parse") }

        let rows = document.treeRows(expanded: document.defaultExpansion())

        XCTAssertEqual(
            rows.map { ($0.key ?? $0.index.map(String.init) ?? "?", $0.depth, $0.isExpanded) }
                .map { "\($0.0)@\($0.1)\($0.2 ? "+" : "")" },
            [
                "questions@0+",
                "0@1+",
                "question@2", "header@2", "multiSelect@2", "options@2",
            ]
        )
        XCTAssertEqual(rows.last?.childCount, 3, "and it says how many options are in there")
    }

    /// Opening a node adds its children directly under it and moves nothing else; closing it
    /// takes its WHOLE subtree away, not just the one level.
    func testOpeningANodeAddsItsSubtreeAndClosingItTakesTheWholeThingAway() {
        guard let document = JSONValue.document(from: Self.execModelInDocumentOrder)
        else { return XCTFail("the fixture must parse") }

        var expanded = document.defaultExpansion()
        let closed = document.treeRows(expanded: expanded)
        guard let options = closed.first(where: { $0.key == "options" }) else {
            return XCTFail("no options row")
        }

        expanded.insert(options.id)
        let opened = document.treeRows(expanded: expanded)
        XCTAssertEqual(opened.count, closed.count + 3, "three options, one level")
        XCTAssertEqual(opened.dropFirst(closed.count - 1).first?.id, options.id)

        // Now the option itself, which is where the three-hundred-character strings live.
        guard let firstOption = opened.first(where: { $0.index == 0 && $0.depth == 3 }) else {
            return XCTFail("no option row")
        }
        expanded.insert(firstOption.id)
        let deep = document.treeRows(expanded: expanded)
        XCTAssertEqual(deep.count, opened.count + 3, "label, description, preview")

        // And closing `questions` at the top takes every one of those away with it.
        guard let questions = deep.first(where: { $0.key == "questions" }) else {
            return XCTFail("no questions row")
        }
        expanded.remove(questions.id)
        XCTAssertEqual(
            document.treeRows(expanded: expanded).count, 1,
            "closing the root member must hide its whole subtree, not one level of it"
        )
    }

    /// The depth rule alone is not safe. A single top-level array of four hundred objects is
    /// two levels deep, and opening it by default is four hundred rows nobody asked for on a
    /// phone. The budget is what stops that, and it stops it without a special case for arrays.
    func testAHugeArrayIsLeftClosedRatherThanOpeningIntoHundredsOfRows() {
        let items = (0..<400).map { #"{"id":\#($0)}"# }.joined(separator: ",")
        guard let document = JSONValue.document(from: #"{"items":[\#(items)]}"#)
        else { return XCTFail("the fixture must parse") }

        let rows = document.treeRows(expanded: document.defaultExpansion())
        XCTAssertEqual(rows.count, 1, "just `items`, closed")
        XCTAssertEqual(rows.first?.childCount, 400, "and it still says how many are in there")
        XCTAssertFalse(rows.first?.isExpanded ?? true)
    }

    /// An empty container is still a container: it draws as `{}` with nothing under it, which
    /// is the honest answer. What it must never report is `isExpanded` — a chevron rotated
    /// open above nothing reads as a row that failed to load, and VoiceOver would announce it
    /// as "Expanded" with no children to move into.
    ///
    /// Asserted against a set that names both of them, not just against the default. The
    /// default never expands an empty container either, so testing only that leaves the rule
    /// resting on a caller who might reasonably do otherwise.
    func testAnEmptyContainerIsNeverExpandedEvenWhenItIsAskedToBe() {
        guard let document = JSONValue.document(from: #"{"opts":{},"tags":[]}"#)
        else { return XCTFail("valid JSON") }

        XCTAssertTrue(
            document.defaultExpansion().isEmpty,
            "nothing to open, so nothing is opened"
        )

        let insisted = Set(document.treeRows(expanded: []).map(\.id))
        let rows = document.treeRows(expanded: insisted)
        XCTAssertEqual(rows.count, 2, "and expanding them adds no rows")
        XCTAssertEqual(rows.map(\.childCount), [0, 0])
        XCTAssertEqual(rows.map(\.isContainer), [true, true])
        XCTAssertEqual(rows.map(\.isExpanded), [false, false])
    }

    // MARK: Fixtures

    private func keys(of text: String) -> [String] {
        guard case .object(let members)? = JSONValue.document(from: text),
              case .array(let questions)? = members.first(where: { $0.key == "questions" })?.value,
              case .object(let question)? = questions.first
        else { return [] }
        return question.map(\.key)
    }

    /// A real `AskUserQuestion` input, pretty-printed the way the Mac sends it — `.sortedKeys`,
    /// so `header` arrives before `question`.
    private static let execModelAsSent = """
        {
          "questions": [
            {
              "header": "Exec model",
              "multiSelect": false,
              "options": [
                {
                  "description": "A workflow = trigger binding + instructions (prompt) + allowed-tool allowlist + output contract. An LLM agent loop decides the steps and calls Mail API tools. Maximally flexible, trivially authorable in plain text, and the allowlist is the safety boundary. Weakness: non-deterministic, harder to test, cost varies per run.",
                  "label": "Agent + tool allowlist (Recommended)",
                  "preview": "name: post-meeting-followup\\ntrigger: { on: TranscriptReady }\\nmodel: claude-sonnet-5\\ntools: [mail.draft, reminders.create, obsidian.append]\\ninstructions: |\\n  Summarize outcomes. Draft a threaded reply to\\n  each external attendee. File my action items as\\n  reminders. Append decisions to the project note.\\noutput: { requires_approval: true }"
                },
                {
                  "description": "A workflow = an ordered list of typed steps (fetch, llm, transform, action). Deterministic, replayable, cheap to test, easy to show a dry-run diff. Weakness: 'arbitrarily define' hits a ceiling fast — anything the step vocabulary doesn't cover needs new engine code.",
                  "label": "Declarative step pipeline",
                  "preview": "steps:\\n  - id: ctx\\n    fetch: meetings.get\\n  - id: prior\\n    fetch: mail.search\\n    q: \\"{{ctx.attendees}}\\"\\n  - id: summary\\n    llm: { prompt: followup.md }\\n  - id: draft\\n    action: mail.draft\\n    replyTo: \\"{{prior.latest.id}}\\""
                },
                {
                  "description": "Deterministic pipeline for context assembly and side effects, with agent steps embedded where judgment is needed. Side effects stay typed and dry-runnable; only the reasoning is non-deterministic. Weakness: two mental models to learn, more engine to build.",
                  "label": "Hybrid: declarative shell, agent steps",
                  "preview": "context:\\n  - meetings.get\\n  - mail.search: \\"{{attendees}}\\"\\n  - slack.search: \\"{{attendees}}\\"\\n\\nagent:\\n  instructions: followup.md\\n  may_call: [draft, remind]\\n\\nemit:\\n  - mail.draft: { approval: required }\\n  - reminders.create: { approval: auto }"
                }
              ],
              "question": "How should an arbitrary user-defined workflow be structured and executed?"
            }
          ]
        }
        """

    /// The same record in the order the agent actually wrote it, which is the order a tool
    /// RESULT carrying JSON arrives in — nothing sorts those.
    private static let execModelInDocumentOrder = """
        {
          "questions": [
            {
              "question": "How should an arbitrary user-defined workflow be structured and executed?",
              "header": "Exec model",
              "multiSelect": false,
              "options": [
                {
                  "label": "Agent + tool allowlist (Recommended)",
                  "description": "A workflow = trigger binding + instructions (prompt) + allowed-tool allowlist + output contract. An LLM agent loop decides the steps and calls Mail API tools. Maximally flexible, trivially authorable in plain text, and the allowlist is the safety boundary. Weakness: non-deterministic, harder to test, cost varies per run.",
                  "preview": "name: post-meeting-followup\\ntrigger: { on: TranscriptReady }\\nmodel: claude-sonnet-5\\ntools: [mail.draft, reminders.create, obsidian.append]\\ninstructions: |\\n  Summarize outcomes. Draft a threaded reply to\\n  each external attendee. File my action items as\\n  reminders. Append decisions to the project note.\\noutput: { requires_approval: true }"
                },
                {
                  "label": "Declarative step pipeline",
                  "description": "A workflow = an ordered list of typed steps (fetch, llm, transform, action). Deterministic, replayable, cheap to test, easy to show a dry-run diff. Weakness: 'arbitrarily define' hits a ceiling fast — anything the step vocabulary doesn't cover needs new engine code.",
                  "preview": "steps:\\n  - id: ctx\\n    fetch: meetings.get\\n  - id: prior\\n    fetch: mail.search\\n    q: \\"{{ctx.attendees}}\\"\\n  - id: summary\\n    llm: { prompt: followup.md }\\n  - id: draft\\n    action: mail.draft\\n    replyTo: \\"{{prior.latest.id}}\\""
                },
                {
                  "label": "Hybrid: declarative shell, agent steps",
                  "description": "Deterministic pipeline for context assembly and side effects, with agent steps embedded where judgment is needed. Side effects stay typed and dry-runnable; only the reasoning is non-deterministic. Weakness: two mental models to learn, more engine to build.",
                  "preview": "context:\\n  - meetings.get\\n  - mail.search: \\"{{attendees}}\\"\\n  - slack.search: \\"{{attendees}}\\"\\n\\nagent:\\n  instructions: followup.md\\n  may_call: [draft, remind]\\n\\nemit:\\n  - mail.draft: { approval: required }\\n  - reminders.create: { approval: auto }"
                }
              ]
            }
          ]
        }
        """
}
