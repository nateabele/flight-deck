import XCTest
import IntakeKit
import FleetKit

/// The first prompt is typed into a live agent through the same gate a phone prompt uses
/// (`PromptText`), so it must always pass that gate — a description pasted with a carriage return
/// or a ten-thousand-character spec would otherwise be refused and the agent would sit idle.
final class TaskPromptTests: XCTestCase {
    func testTemplateIsTheSpecs() {
        let text = TaskPrompt.text(for: TaskDetail(id: "fd-3x9", title: "Add snapshot tests",
                                                   description: "Cover the parser.",
                                                   acceptance: "- every fixture has a snapshot",
                                                   status: "in_progress", assignee: "BlueLake"))
        XCTAssertEqual(text, """
            Your task is fd-3x9: Add snapshot tests.

            Cover the parser.

            Acceptance criteria:
            - every fixture has a snapshot

            Reserve the files you will edit with Agent Mail before you edit them.
            When the acceptance criteria hold and your work is committed, run `br close fd-3x9`.
            If you are blocked, say so in one line that starts with BLOCKED:, then stop.
            """)
    }

    func testEmptySectionsAreOmitted() {
        let text = TaskPrompt.text(for: TaskDetail(id: "a", title: "T", description: "  ", acceptance: "",
                                                   status: "open", assignee: nil))
        XCTAssertFalse(text.contains("Acceptance criteria:"))
        XCTAssertTrue(text.hasPrefix("Your task is a: T.\n\nReserve the files"))
    }

    func testControlCharactersAreStrippedSoThePromptPassesTheGate() {
        let text = TaskPrompt.text(for: TaskDetail(id: "a", title: "T", description: "line1\r\nline2\u{1B}[0m\u{07}",
                                                   acceptance: "ok\tfine", status: "open", assignee: nil))
        XCTAssertNil(PromptText.rejection(for: text))
        XCTAssertTrue(text.contains("line1\nline2[0m"))
        XCTAssertTrue(text.contains("ok\tfine"))
    }

    func testLongBodiesAreCutToTheBudgetWithAPointer() {
        let long = String(repeating: "word ", count: 4_000)
        let text = TaskPrompt.text(for: TaskDetail(id: "fd-1", title: "T", description: long, acceptance: long,
                                                   status: "open", assignee: nil))
        XCTAssertLessThanOrEqual(text.count, TaskPrompt.budget)
        XCTAssertNil(PromptText.rejection(for: text))
        XCTAssertTrue(text.contains("run `br show fd-1` for the rest"))
        XCTAssertTrue(text.hasSuffix("If you are blocked, say so in one line that starts with BLOCKED:, then stop."))
    }
}
