import FleetKit
import XCTest

/// `TaskNotification.parse`: reading a task's outcome out of the flat run of
/// `<label>value</label>` pairs `ClaudeTimelineMapper.normalized` hands a `.systemNotice` for
/// `tool == "task-notification"`.
///
/// It runs on macOS because `TaskNotification` is in `FleetKit` and `FleetKit` is where both
/// platforms meet — the same justification `JSONValueTests` and `TimelineFeedTests` give.
/// Task 2's rendering is not this file's concern; this file only checks what the struct holds.
final class TaskNotificationTests: XCTestCase {

    /// A real record, captured whole rather than trimmed down, so a rule that only breaks on
    /// a shape this test would otherwise omit — the `<usage>` field's own nested tags, in
    /// particular — still gets exercised.
    private static let realRecord = """
        <task-id>a09ec251ce8bf1e2d</task-id>
        <tool-use-id>toolu_011UTbMqwEPEvNQPDJZshN7i</tool-use-id>
        <output-file>/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-Schedule/cdf92b5f-0e3a-4f42-b3b1-6ea59e168ff5/tasks/a09ec251ce8bf1e2d.output</output-file>
        <status>completed</status>
        <summary>Agent "Implement sidebar sections feature" finished</summary>
        <note>A task-notification fires each time this agent stops with no live background children of its own. The user can send it another message and resume it, so the same task-id may notify more than once.</note>
        <result>Status: DONE

        Commit SHA: `ffdbcff` on `feature/sidebar-sections`

        Test summary: `swift test` \u{2192} 157 tests in 15 suites passed (145 baseline + 12 new), run twice to confirm no flakiness.

        Concern: found and fixed a test-isolation bug in my own first draft \u{2014} three new bulk-visibility tests initially reused `CalendarStoreTests.makeStore()`, which is backed by the real, disk-persisted `CalendarPreferences()` (pre-existing pattern, not something I introduced), and left `personal`/`family` calendars hidden on disk, breaking the pre-existing `"Toggle calendar visibility"` test. Fixed by adding an ephemeral `makeIsolatedStore()` helper for those tests and scrubbed the polluted real defaults domain (`defaults delete com.schedule.app.preferences`). Full detail in `/Users/nate/Projects/Protos-n-Tools/Schedule/.superpowers/sdd/jiggly-baking-valiant/task-1-report.md`.</result>
        <usage><subagent_tokens>65202</subagent_tokens><tool_uses>36</tool_uses><duration_ms>232625</duration_ms></usage>
        """

    func testARealRecordReadsSummaryStatusResultAndTheRemainingFieldsInOrder() {
        guard let notification = TaskNotification.parse(Self.realRecord) else {
            return XCTFail("this is exactly the shape a task-notification body takes")
        }

        XCTAssertEqual(notification.summary, "Agent \"Implement sidebar sections feature\" finished")
        XCTAssertEqual(notification.status, "completed")
        XCTAssertTrue(notification.result?.hasPrefix("Status: DONE") == true)
        // `usage` is not one of the three named fields and is not `note`, so rule 4 keeps it —
        // an unrecognised label surviving into `fields` is the whole point of that rule, and
        // this is the real harness label that motivated it, not a label invented for the test.
        XCTAssertEqual(notification.fields.map(\.label), ["task-id", "tool-use-id", "output-file", "usage"])
    }

    func testNoteIsDroppedEntirelyRatherThanKeptAsAField() {
        guard let notification = TaskNotification.parse(Self.realRecord) else {
            return XCTFail("this is exactly the shape a task-notification body takes")
        }

        XCTAssertFalse(notification.fields.map(\.label).contains("note"))
    }

    func testAnUnknownLabelIsKeptInFieldsRatherThanDropped() {
        let body = "<status>completed</status><queue-depth>3</queue-depth>"

        guard let notification = TaskNotification.parse(body) else {
            return XCTFail("a run of closed tags is this shape")
        }

        XCTAssertEqual(notification.fields, [TaskNotification.Field(label: "queue-depth", value: "3")])
    }

    /// The test that fails if the parser ends a field at the next `<` instead of at its own
    /// matching closing tag: a `<result>` this shape holds is markdown, and markdown routinely
    /// carries backticks, generic types and comparisons that are not the end of the field.
    func testAResultContainingAngleBracketsAndBackticksSurvivesIntact() {
        let body = "<result>Compare `List<Item>` and `a < b`, then `c > d`.</result>"

        guard let notification = TaskNotification.parse(body) else {
            return XCTFail("a closed <result> tag is this shape")
        }

        XCTAssertEqual(notification.result, "Compare `List<Item>` and `a < b`, then `c > d`.")
    }

    func testOrdinaryProseWithNoTagsReturnsNil() {
        let body = "Your session is being continued from a previous conversation that ran out of context."

        XCTAssertNil(TaskNotification.parse(body))
    }

    func testAnEmptyStringReturnsNil() {
        XCTAssertNil(TaskNotification.parse(""))
    }

    /// Matches `ClaudeTimelineMapper.normalized`'s own rule for an unclosed wrapper: the
    /// remainder becomes the field's value rather than the whole body being refused, because
    /// an unclosed final tag is what a body cut at a byte cap looks like, same as anywhere
    /// else in this pipeline.
    func testAnUnclosedFinalFieldTakesTheRemainderAsItsValue() {
        let body = "<status>completed</status><result>Status: DONE, still writ"

        guard let notification = TaskNotification.parse(body) else {
            return XCTFail("a closed field ahead of an unclosed one is still this shape")
        }

        XCTAssertEqual(notification.result, "Status: DONE, still writ")
    }
}
