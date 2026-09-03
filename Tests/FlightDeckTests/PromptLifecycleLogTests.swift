import XCTest
@testable import FlightDeck

/// The two records this Mac writes when it cannot afford to stay silent about a dialog it
/// cannot name: `stuck`, a second tick later, and `aborted`, an Escape sent blind at one.
///
/// Companion to `PromptLifecycleTests`, which owns the records `SessionStore` derives from a
/// live transcript. These two are constructed directly here because nothing in the production
/// loop emits them yet — that wiring is a later task in this series, and this task is only the
/// case and its rendering.
final class PromptLifecycleLogTests: XCTestCase {
    func testStuckRecordNamesBothPathsAndTheVerdict() {
        let record = PromptLifecycleRecord(
            session: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            event: .stuck(
                code: "prompt_changed",
                watched: "/p/-a-b/x.jsonl", registryCWD: "/a/b/.claude/worktrees/w",
                pathMatches: false, fileAgeMS: 61_000, lastRecordAgeMS: 61_000, tailRecords: 8
            )
        )
        XCTAssertTrue(record.summary.contains("stuck code=prompt_changed"))
        XCTAssertTrue(record.summary.contains("pathMatches=false"))
        XCTAssertTrue(record.summary.contains("watched=/p/-a-b/x.jsonl"))
        XCTAssertTrue(record.summary.contains("registryCwd=/a/b/.claude/worktrees/w"))
        XCTAssertTrue(record.summary.contains("fileAgeMs=61000"))
        XCTAssertTrue(record.summary.contains("lastRecordAgeMs=61000"))
    }

    func testAbortedRecordDistinguishesDispatchFromRefusal() {
        let ok = PromptLifecycleRecord(session: UUID(), event: .aborted(code: nil))
        XCTAssertTrue(ok.summary.contains("abort code=ok"))
        let no = PromptLifecycleRecord(session: UUID(), event: .aborted(code: "not_waiting"))
        XCTAssertTrue(no.summary.contains("abort code=not_waiting"))
    }
}
