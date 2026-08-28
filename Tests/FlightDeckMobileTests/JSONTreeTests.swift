import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone's half of the tool-body tree: which bodies are offered as one at all, what a row
/// says, and what VoiceOver hears.
///
/// The parser and the flattening are `FleetKit`'s and are run by `FlightDeckTests/JSONValueTests`
/// on macOS. What is here is everything the *screen* decides — and, first among them, the three
/// gates that keep this feature from making the screen worse than the plain text it replaced.
///
/// Layout is not here and must not be: whether a 300-character value wraps or how far a fifth
/// indent level pushes a column is not reachable from a test process. docs/MOBILE.md's checklist
/// and the offscreen renders own that.
final class JSONTreeTests: XCTestCase {

    // MARK: Which bodies get a tree

    /// A truncated body is not parseable JSON *by design* — the Mac cuts at
    /// `TimelineLimits.maxItemBytes` wherever that lands, and the fixture is a real
    /// `AskUserQuestion` input cut mid-word inside a `description`. It must fall back to its
    /// text, and the truncation must still be disclosed by the block that draws it.
    ///
    /// **There is deliberately no rule about `truncatedBytes` anywhere in this path.** The
    /// parse failing IS the rule; a separate short-circuit would be a second thing to keep in
    /// step with the first.
    func testATruncatedBodyFallsBackToItsTextRatherThanShowingAParseError() {
        let cut = TimelineFixtures.askUserQuestionTruncated

        XCTAssertNil(TimelineStyle.jsonDocument(for: cut))
        XCTAssertGreaterThan(cut.body.truncatedBytes, 0, "the fixture must actually be cut")
        XCTAssertNotNil(
            TimelineStyle.jsonDocument(for: TimelineFixtures.askUserQuestionCall),
            "and the same input, whole, must parse — or this test proves nothing"
        )
    }

    /// A tool result is usually `ls` output, a diff or a stack trace, and none of that is JSON.
    /// The minority that IS a document gets a tree, on the output panel as well as the input —
    /// an async `Agent` dispatch answers with one.
    func testAToolResultGetsATreeOnlyWhenItReallyIsADocument() {
        XCTAssertNil(TimelineStyle.jsonDocument(for: TimelineFixtures.readResult))
        XCTAssertNil(TimelineStyle.jsonDocument(for: TimelineFixtures.bashResult))
        XCTAssertNil(TimelineStyle.jsonDocument(for: TimelineFixtures.failingResult))
        XCTAssertNotNil(TimelineStyle.jsonDocument(for: TimelineFixtures.agentLaunchResult))
    }

    /// Prose is never offered a tree, even in the case where it would parse.
    ///
    /// `.unknown` is the sharp one: the fixture's body genuinely IS a JSON object, and that
    /// block's whole promise is that it shows what arrived "exactly as it arrived" — a tree is
    /// an interpretation, and offering one there would contradict the note printed beside it.
    func testProseAndUnrecognizedKindsAreNeverOfferedATreeEvenWhenTheyWouldParse() {
        XCTAssertNotNil(
            JSONValue.document(from: TimelineFixtures.unknown.body.text),
            "the fixture's body is JSON — that is what makes this test worth having"
        )
        XCTAssertNil(TimelineStyle.jsonDocument(for: TimelineFixtures.unknown))

        let prose = [
            TimelineFixtures.userTurn, TimelineFixtures.assistantAnswer,
            TimelineFixtures.thinking, TimelineFixtures.prompt,
        ]
        for item in prose {
            XCTAssertNil(TimelineStyle.jsonDocument(for: item), item.id)
        }
    }

    // MARK: What a row says

    /// A container says its size in BOTH states. Collapsed it is the only thing telling a
    /// reader there is anything in there; expanded it is the only thing telling them whether
    /// they have seen all four options or scrolled past one, because the panel has no closing
    /// brace to look at.
    func testAContainerSaysHowManyChildrenItHasWhetherOpenOrClosed() {
        XCTAssertEqual(TimelineStyle.jsonValueText(for: .array([.null, .null, .null])), "[3]")
        XCTAssertEqual(
            TimelineStyle.jsonValueText(for: .object([.init(key: "a", value: .null)])), "{1}"
        )
        // Empty is drawn as empty rather than as `{0}`, which reads like a count of nothing.
        XCTAssertEqual(TimelineStyle.jsonValueText(for: .object([])), "{}")
        XCTAssertEqual(TimelineStyle.jsonValueText(for: .array([])), "[]")
    }

    /// Strings keep their quotes. The tree tints by type, but a tint is unreadable in greyscale
    /// and to a reader who cannot distinguish it — and `"true"` and `true` are two different
    /// answers to a tool's flag.
    func testAStringKeepsItsQuotesSoItIsNotConfusedWithTheValueItSpells() {
        XCTAssertEqual(TimelineStyle.jsonValueText(for: .string("true")), "\"true\"")
        XCTAssertEqual(TimelineStyle.jsonValueText(for: .bool(true)), "true")
        XCTAssertEqual(TimelineStyle.jsonValueText(for: .string("")), "\"\"")
        XCTAssertEqual(TimelineStyle.jsonValueText(for: .null), "null")
        // The lexeme, not a re-formatted number. See `JSONValue.number`.
        XCTAssertEqual(TimelineStyle.jsonValueText(for: .number("1.50")), "1.50")
    }

    /// An array element is LABELLED by its zero-based index, because that is the index anyone
    /// reading the JSON beside it will use. A member is labelled by its key.
    func testAnArrayElementIsLabelledByItsIndexAndAMemberByItsKey() {
        guard let document = TimelineStyle.jsonDocument(for: TimelineFixtures.browserBatchCall)
        else { return XCTFail("the fixture must parse") }

        let rows = document.treeRows(expanded: document.defaultExpansion())
        XCTAssertEqual(
            rows.map { "\(TimelineStyle.jsonLabel(for: $0))@\($0.depth)" },
            [
                "actions@0",
                "0@1", "input@2", "name@2",
                "1@1", "input@2", "name@2",
                "2@1", "input@2", "name@2",
                "3@1", "input@2", "name@2",
            ],
            "four batched actions, each opened one level"
        )
    }

    // MARK: What VoiceOver hears

    /// A row is one stop and one sentence, and a container has to say its size and whether it
    /// is open — a VoiceOver user has no chevron to look at, so without it the row announces
    /// nothing about what activating it would do.
    func testVoiceOverHearsAContainersSizeAndWhetherItIsOpen() {
        let collapsed = JSONTreeRow(
            id: "/0", depth: 0, key: "options", index: nil,
            value: .array([.null, .null, .null]), isExpanded: false
        )
        XCTAssertEqual(
            TimelineStyle.accessibilityLabel(forJSON: collapsed),
            "options, Array, 3 items, Collapsed"
        )

        let opened = JSONTreeRow(
            id: "/0", depth: 0, key: "options", index: nil,
            value: .array([.null]), isExpanded: true
        )
        XCTAssertEqual(
            TimelineStyle.accessibilityLabel(forJSON: opened),
            "options, Array, 1 item, Expanded"
        )
    }

    /// Spoken one-based. "Item 0" is a programmer's index read aloud to someone counting, and
    /// the row it names is the first one.
    func testVoiceOverCountsArrayElementsFromOneEvenThoughTheLabelStartsAtZero() {
        let row = JSONTreeRow(
            id: "/0/0", depth: 1, key: nil, index: 0,
            value: .object([.init(key: "name", value: .string("computer"))]), isExpanded: false
        )
        XCTAssertEqual(TimelineStyle.jsonLabel(for: row), "0")
        XCTAssertEqual(
            TimelineStyle.accessibilityLabel(forJSON: row),
            "Item 1, Object, 1 entry, Collapsed"
        )
    }

    /// **Capped, for the same reason a whole row's label is.** A real `AskUserQuestion` option
    /// carries a `description` past three hundred characters, and a tree of four options is
    /// four of those read out with no way to skip past one.
    func testVoiceOverDoesNotReadAWholeThreeHundredCharacterOptionDescription() {
        guard let document = TimelineStyle.jsonDocument(for: TimelineFixtures.askUserQuestionCall)
        else { return XCTFail("the fixture must parse") }

        // Open everything, so the long leaves are reachable.
        var expanded: Set<String> = []
        var rows = document.treeRows(expanded: expanded)
        while rows.contains(where: { $0.isContainer && !$0.isExpanded && $0.childCount > 0 }) {
            expanded.formUnion(rows.filter(\.isContainer).map(\.id))
            rows = document.treeRows(expanded: expanded)
        }

        guard let long = rows.first(where: {
            if case .string(let text) = $0.value { return text.count > 240 }
            return false
        }) else { return XCTFail("the fixture must carry a description past 240 characters") }

        let spoken = TimelineStyle.accessibilityLabel(forJSON: long)
        XCTAssertTrue(spoken.hasPrefix("description, "), spoken)
        XCTAssertTrue(spoken.hasSuffix("…"), "must be cut, not read whole: \(spoken)")
        XCTAssertLessThan(spoken.count, 280, spoken)
    }
}
