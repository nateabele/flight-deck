import XCTest
@testable import FlightDeck

/// The two records this Mac writes when it cannot afford to stay silent about a dialog it
/// cannot name: `stuck`, some seconds into a blocked episode, and `aborted`, an Escape sent
/// blind at one.
///
/// Companion to `PromptLifecycleTests`, which owns the records `SessionStore` derives from a
/// live transcript. **This file owns the rendering and nothing else**, so every record here is
/// constructed by hand. That is a deliberate boundary, not a gap — but it was read as coverage
/// once and must not be again: an earlier version of this comment said "nothing in the
/// production loop emits them yet", which stayed on the page after the wiring landed and is
/// plausibly why the emission went unasserted for a whole branch. Whether the production loop
/// emits a `.stuck` at all — and when, and how many times — is
/// `SessionStoreStuckPromptTests`'s; whether an abort emits one is
/// `AbortPromptLoopbackTests`'. Deleting a `promptLifecycleSink(...)` call must fail a test
/// there, never here.
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
        let ok = PromptLifecycleRecord(
            session: UUID(),
            event: .aborted(code: nil, sent: true, probe: .unnameable(code: "prompt_changed"))
        )
        XCTAssertTrue(ok.summary.contains("abort code=ok"))
        let no = PromptLifecycleRecord(
            session: UUID(),
            event: .aborted(code: "not_waiting", sent: false, probe: .unavailable)
        )
        XCTAssertTrue(no.summary.contains("abort code=not_waiting"))
    }

    /// **A dispatched abort and a replayed one both report `code=ok`.** `.duplicate`'s
    /// `errorCode` is `nil` by design — "a retry that lands is an answer that landed" — so
    /// without `sent` the log could not say how many Escapes this Mac actually typed, which is
    /// the first thing anyone counting keystrokes into someone's terminal would ask of it.
    func testAbortedRecordTellsAKeystrokeFromANoOp() {
        let session = UUID()
        func summary(sent: Bool) -> String {
            PromptLifecycleRecord(
                session: session,
                event: .aborted(
                    code: nil, sent: sent, probe: .unnameable(code: "prompt_changed")
                )
            ).summary
        }
        XCTAssertTrue(summary(sent: true).contains("sent=true"))
        XCTAssertTrue(summary(sent: false).contains("sent=false"))
        XCTAssertNotEqual(
            summary(sent: true), summary(sent: false),
            "two records that differ only in whether a key was typed must not render alike"
        )
    }

    /// **The question the escape hatch's safety story rests on**: was this blind Escape aimed
    /// at a dialog this Mac genuinely could not name? All three verdicts have to be legible,
    /// and "no probe was installed" must not read as "the probe found nothing".
    func testAbortedRecordCarriesWhatThisMacBelievedAboutTheDialog() {
        func summary(_ probe: PromptLifecycleRecord.AbortProbe) -> String {
            PromptLifecycleRecord(
                session: UUID(), event: .aborted(code: nil, sent: true, probe: probe)
            ).summary
        }
        XCTAssertTrue(summary(.nameable).contains("probe=nameable"))
        XCTAssertTrue(
            summary(.unnameable(code: "prompt_changed")).contains("probe=unnameable-prompt_changed")
        )
        XCTAssertTrue(summary(.unavailable).contains("probe=-"))
    }
}
