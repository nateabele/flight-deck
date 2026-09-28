import XCTest
@testable import FlightDeck

/// Pins how an intake's title is cut from its intent — the detail header's title and the list
/// row's bold lead-in both read it, so a regression shows up in two places at once.
final class IntakeTitleTests: XCTestCase {
    private func title(_ intent: String) -> String { IntakeTitle(intent: intent).title }

    // MARK: - Sentences

    func testTheFirstSentenceIsTheTitleAndItsPeriodIsDropped() {
        let t = IntakeTitle(intent: "Add a contributor note to the README. It should link to the release ritual.")
        XCTAssertEqual(t.title, "Add a contributor note to the README")
        XCTAssertEqual(t.lead, "Add a contributor note to the README.")
        XCTAssertEqual(t.rest, "It should link to the release ritual.")
        XCTAssertFalse(t.isWhole)
    }

    func testAQuestionOrExclamationKeepsItsMark() {
        XCTAssertEqual(title("Can the dock hide itself? It covers the board."), "Can the dock hide itself?")
        XCTAssertEqual(title("Stop the flicker! It happens on every resize."), "Stop the flicker!")
    }

    func testAOneSentenceIntentIsWhole() {
        let t = IntakeTitle(intent: "  Add a contributor note to the README.  ")
        XCTAssertEqual(t.title, "Add a contributor note to the README")
        XCTAssertEqual(t.rest, "")
        XCTAssertTrue(t.isWhole, "one short sentence needs no Request section — the title already says it all")
    }

    func testAbbreviationsDoNotEndASentence() {
        XCTAssertEqual(title("Cache small assets, e.g. icons and fonts. Then measure."), "Cache small assets, e.g. icons and fonts")
        XCTAssertEqual(title("Use the old path, i.e. Sources/Legacy. Then delete it."), "Use the old path, i.e. Sources/Legacy")
        XCTAssertEqual(title("Compare SQLite vs. Postgres for the log. Pick one."), "Compare SQLite vs. Postgres for the log")
    }

    func testALowercaseContinuationDoesNotEndASentence() {
        // An abbreviation the list doesn't know ("approx.") followed by lowercase is still one sentence.
        XCTAssertEqual(title("Trim it to approx. ten lines. Keep the badge."), "Trim it to approx. ten lines")
    }

    func testDecimalsVersionsAndURLsDoNotSplit() {
        XCTAssertEqual(title("Bump the timeout to 2.5 seconds. It flakes."), "Bump the timeout to 2.5 seconds")
        XCTAssertEqual(title("Pin ghostty v1.3.1 again. The bump broke kitty."), "Pin ghostty v1.3.1 again")
        XCTAssertEqual(title("Mirror https://example.com/docs/v2.1/index.html locally. Nightly."),
                       "Mirror https://example.com/docs/v2.1/index.html locally")
    }

    func testAClosingQuoteOrParenStaysWithItsSentence() {
        let t = IntakeTitle(intent: "Rename the menu item (it says \"Close Tab.\") Then fix the shortcut.")
        XCTAssertEqual(t.lead, "Rename the menu item (it says \"Close Tab.\")")
        XCTAssertEqual(t.rest, "Then fix the shortcut.")
    }

    func testALineBreakEndsTheTitle() {
        let t = IntakeTitle(intent: "Sidebar polish\n\n- wrap the rows\n- calmer header")
        XCTAssertEqual(t.title, "Sidebar polish")
        XCTAssertEqual(t.rest, "- wrap the rows - calmer header", "the rest is folded to one line for the row preview")
    }

    // MARK: - Long first sentences

    func testALongSentenceCutsAtAClauseBreakWithoutAnEllipsis() {
        let t = IntakeTitle(intent: "Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in")
        XCTAssertEqual(t.title, "Build a field-service scheduling platform")
        XCTAssertEqual(t.lead, "Build a field-service scheduling platform:")
        XCTAssertEqual(t.rest, "technicians, jobs, a dispatch board and mobile check-in")
    }

    func testAnEmDashIsAClauseBreakToo() {
        XCTAssertEqual(title("Make the intake rows taller — show two or three lines of each request so the list can be scanned without opening anything"),
                       "Make the intake rows taller")
    }

    func testAClauseBreakTooEarlyIsIgnored() {
        // "Fix:" would be a useless title; the word cut reads better.
        let t = IntakeTitle(intent: "Fix: the departures board flaps every slot again whenever the pane is resized, even when nothing changed at all")
        XCTAssertTrue(t.title.hasPrefix("Fix: the departures board"), t.title)
        XCTAssertTrue(t.title.hasSuffix("…"))
    }

    func testALongSentenceWithNoClauseBreakCutsAtAWordWithAnEllipsis() {
        let intent = "Teach the intake list to wrap each request over a few lines so there is enough context to tell similar requests apart at a glance"
        let t = IntakeTitle(intent: intent)
        XCTAssertLessThanOrEqual(t.title.count, IntakeTitle.limit)
        XCTAssertTrue(t.title.hasSuffix("…"))
        let body = String(t.title.dropLast())
        XCTAssertTrue(intent.hasPrefix(body))
        XCTAssertEqual(intent[intent.index(intent.startIndex, offsetBy: body.count)], " ", "the cut lands on a word boundary")
        XCTAssertEqual(t.lead + " " + t.rest, intent, "lead and rest rejoin into the whole request")
    }

    func testWithNoClauseBreakALongSentenceCutsAtItsLastCommaInReach() {
        // Beats the word cut: bold running into regular mid-phrase ("…monorepos where | the graph")
        // read as a rendering glitch in the list row.
        let t = IntakeTitle(intent: "Bump the triage timeout to 2.5 seconds, e.g. for large monorepos where the graph read is slow. It flakes.")
        XCTAssertEqual(t.title, "Bump the triage timeout to 2.5 seconds…")
        XCTAssertEqual(t.lead, "Bump the triage timeout to 2.5 seconds,")
        XCTAssertEqual(t.rest, "e.g. for large monorepos where the graph read is slow. It flakes.")
    }

    func testAWordCutNeverLeavesDanglingPunctuationBeforeTheEllipsis() {
        // The last whole word inside the window is "&": the title must not end "abc &…".
        let intent = String(repeating: "word ", count: 13) + "abc & more words to push it past the limit"
        let t = IntakeTitle(intent: intent)
        XCTAssertEqual(t.title, String(repeating: "word ", count: 13) + "abc…")
        XCTAssertEqual(t.lead + " " + t.rest, intent)
    }

    func testOneGiantTokenIsHardCut() {
        let url = "https://example.com/" + String(repeating: "a", count: 200)
        let t = IntakeTitle(intent: url)
        XCTAssertEqual(t.title.count, IntakeTitle.limit)
        XCTAssertTrue(t.title.hasSuffix("…"))
        XCTAssertFalse(t.isWhole)
    }

    // MARK: - Degenerate input

    func testEmptyAndWhitespaceIntentsHaveNoTitle() {
        for intent in ["", "   ", "\n\t \n"] {
            let t = IntakeTitle(intent: intent)
            XCTAssertEqual(t.title, "")
            XCTAssertEqual(t.rest, "")
            XCTAssertTrue(t.isWhole)
        }
    }

    func testRunsOfWhitespaceFoldToOneSpace() {
        XCTAssertEqual(title("Fix   the\tflicker"), "Fix the flicker")
    }

    func testWordCount() {
        XCTAssertEqual(IntakeTitle.wordCount("Add a  note\nto the README."), 6)
        XCTAssertEqual(IntakeTitle.wordCount("   "), 0)
    }
}
