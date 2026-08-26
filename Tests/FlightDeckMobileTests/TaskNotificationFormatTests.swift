import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The decisions behind the task-notification row, which are the parts a test in this process
/// can reach. SwiftUI layout is not one of them — `docs/MOBILE.md` says so — so what is pinned
/// here is what the row *says*, never where it puts it.
final class TaskNotificationFormatTests: XCTestCase {

    // MARK: The rule that keeps markup off the screen

    /// **The whole feature in one assertion.** `usage` arrives with its value set to
    /// `<subagent_tokens>65202</subagent_tokens>…` verbatim, and the parser unpacks that into
    /// `children`. A renderer that drew `value` anyway would print raw angle brackets inside
    /// the row built specifically to stop printing raw angle brackets — the original defect,
    /// one field smaller.
    func testAFieldWithChildrenDrawsThemAndNeverItsOwnMarkup() {
        let usage = TaskNotification.Field(
            label: "usage",
            value: "<subagent_tokens>65202</subagent_tokens><tool_uses>36</tool_uses>"
                + "<duration_ms>232625</duration_ms>",
            children: [
                .init(label: "subagent_tokens", value: "65202"),
                .init(label: "tool_uses", value: "36"),
                .init(label: "duration_ms", value: "232625"),
            ]
        )

        let shown = TaskNotificationFormat.displayValue(for: usage)

        XCTAssertFalse(shown.contains("<"), "a row that still shows a tag has not been fixed")
        XCTAssertFalse(shown.contains(">"))
        XCTAssertTrue(shown.contains("tokens"), "and it says what the numbers mean")
        XCTAssertTrue(shown.contains("36 tools"))
        XCTAssertTrue(shown.contains("3m 53s"), "232625ms, to the second")
    }

    /// A leaf still shows its own value. The guard above must not swallow the ordinary case.
    func testALeafFieldDrawsItsValueUnchanged() {
        let field = TaskNotification.Field(label: "task-id", value: "acff27d277cceb622")
        XCTAssertEqual(TaskNotificationFormat.displayValue(for: field), "acff27d277cceb622")
    }

    // MARK: Words, not numbers

    func testADurationReadsAsOneRatherThanAsMilliseconds() {
        XCTAssertEqual(TaskNotificationFormat.duration(milliseconds: 232_625), "3m 53s")
        XCTAssertEqual(TaskNotificationFormat.duration(milliseconds: 8_400), "8s")
        XCTAssertEqual(TaskNotificationFormat.duration(milliseconds: 60_000), "1m 0s")
        XCTAssertEqual(TaskNotificationFormat.duration(milliseconds: 7_384_000), "2h 3m")
    }

    /// One tool is not "1 tools". A plural that is wrong on the singular case is the kind of
    /// thing a reader notices every time and nobody ever fixes.
    func testASingleToolUseIsNotPluralised() {
        let one = TaskNotification.Field(label: "tool_uses", value: "1")
        XCTAssertEqual(TaskNotificationFormat.child(one), "1 tool")
    }

    /// A child whose value is not a number is shown as it came rather than dropped or
    /// rendered as a zero. The harness owns this format and can change it.
    func testANonNumericChildIsShownRatherThanSilentlyBecomingZero() {
        let odd = TaskNotification.Field(label: "duration_ms", value: "unknown")
        XCTAssertEqual(TaskNotificationFormat.child(odd), "unknown")
    }

    /// An unrecognised child still reads, because the alternative is a field that silently
    /// vanishes the month the harness adds one.
    func testAnUnknownChildIsNamedAndShownRatherThanHidden() {
        let future = TaskNotification.Field(label: "cache_hits", value: "12")
        XCTAssertEqual(TaskNotificationFormat.child(future), "cache hits 12")
    }

    // MARK: Labels

    func testTheThreeKnownLabelsGetShortNamesAndAnythingElseKeepsItsOwn() {
        XCTAssertEqual(TaskNotificationFormat.label(for: "task-id"), "task")
        XCTAssertEqual(TaskNotificationFormat.label(for: "tool-use-id"), "call")
        XCTAssertEqual(TaskNotificationFormat.label(for: "output-file"), "output")
        XCTAssertEqual(TaskNotificationFormat.label(for: "queue-depth"), "queue depth",
                       "an unrecognised field appears, readable, with no build here")
    }

    // MARK: What the budget is spent on

    /// The 14-line cap is unchanged; what changed is that it is spent on the agent's report
    /// instead of on counting `<tool-use-id>` lines.
    func testALongResultIsClampedForACollapsedRowAndWholeForAnExpandedOne() {
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")

        let collapsed = TaskNotificationFormat.clampedResult(long, expanded: false)
        let whole = TaskNotificationFormat.clampedResult(long, expanded: true)

        XCTAssertTrue(collapsed.hasMore, "40 lines is past the ceiling, and the row says so")
        XCTAssertFalse(whole.hasMore, "an expanded row draws all of it")
    }

    func testAShortResultIsNeverClaimedToHaveMore() {
        let short = "Status: Complete.\nCommit: `dcae2a7`"
        XCTAssertFalse(TaskNotificationFormat.clampedResult(short, expanded: false).hasMore)
    }

    // MARK: What a listener hears, and what lands on the clipboard

    /// **The same defect, in the modality a reader cannot skim past.** `spoken` exists because
    /// `TimelineStyle.spoken` fell through to `body.text` for a `.systemNotice`, so VoiceOver
    /// announced "less-than task-id greater-than acff…" — the row was fixed and the
    /// announcement was not. It is also what the detail screen's Copy button puts on the
    /// clipboard, for the same reason: a button beside the readable version must not hand back
    /// the markup.
    func testWhatIsSpokenAndCopiedCarriesNoMarkup() {
        let notification = TaskNotification(
            summary: "Agent \"Filter events\" finished",
            status: "completed",
            result: "Status: Complete.",
            fields: [
                .init(label: "task-id", value: "acff27d277cceb622"),
                .init(
                    label: "usage",
                    value: "<subagent_tokens>65202</subagent_tokens>",
                    children: [.init(label: "subagent_tokens", value: "65202")]
                ),
            ]
        )

        let spoken = TaskNotificationFormat.spoken(notification)

        XCTAssertFalse(spoken.contains("<"), "a listener must not hear a tag")
        XCTAssertFalse(spoken.contains(">"))
        XCTAssertTrue(spoken.contains("Agent \"Filter events\" finished"))
        XCTAssertTrue(spoken.contains("completed"), "including whether it worked")
        XCTAssertTrue(spoken.contains("Status: Complete."), "and the report itself")
        XCTAssertTrue(spoken.contains("tokens"), "nested values speak as words, not markup")
    }

    /// The row's own announcement goes through the same function, so the two cannot drift.
    func testTheRowsAccessibleTextUsesTheParseRatherThanTheRawBody() {
        let item = TimelineItem(
            id: "1000#0", kind: .systemNotice, status: .complete,
            body: TimelineItem.Body(
                text: "<status>completed</status>\n<summary>Agent finished</summary>",
                tool: "task-notification"
            )
        )

        let spoken = TimelineStyle.spoken(item)

        XCTAssertFalse(spoken.contains("<status>"), "the raw body must not reach a listener")
        XCTAssertTrue(spoken.contains("Agent finished"))
    }

    // MARK: The gate

    /// A `system-reminder` is ordinary prose under a wrapper, not a run of fields. It must take
    /// the path it always took — this is the assertion that says the new branch cannot capture
    /// every notice on the screen.
    func testANoticeThatIsNotAFieldRunIsNotTreatedAsANotification() {
        let reminder = TimelineItem(
            id: "1000#0", kind: .systemNotice, status: .complete,
            body: TimelineItem.Body(
                text: "Your session is being continued from a previous conversation.",
                tool: "system-reminder"
            )
        )
        XCTAssertNil(TimelineStyle.taskNotification(for: reminder))
    }

    /// And the kind gate holds: an assistant message that happened to contain field-shaped text
    /// is the agent's own words, not a notification.
    func testAnAssistantMessageIsNeverParsedAsANotification() {
        let assistant = TimelineItem(
            id: "1000#0", kind: .assistantText, status: .complete,
            body: TimelineItem.Body(text: "<status>completed</status>")
        )
        XCTAssertNil(TimelineStyle.taskNotification(for: assistant))
    }
}
