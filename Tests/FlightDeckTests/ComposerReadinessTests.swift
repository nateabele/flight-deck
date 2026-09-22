import XCTest
@testable import FlightDeck

final class ComposerReadinessTests: XCTestCase {
    private let id = UUID(uuidString: "b16a1e73-b93e-4493-a396-46adc4cf02ee")!

    func testDecodesSessionIDAndEventName() {
        let line = #"{"hook_event_name":"Stop","session_id":"b16a1e73-b93e-4493-a396-46adc4cf02ee","cwd":"/w"}"#
        XCTAssertEqual(
            HookEventRecord.decode(line),
            HookEventRecord(sessionID: id, event: "Stop")
        )
    }

    func testRejectsGarbageRatherThanGuessing() {
        XCTAssertNil(HookEventRecord.decode(""))
        XCTAssertNil(HookEventRecord.decode("not json"))
        XCTAssertNil(HookEventRecord.decode(#"{"hook_event_name":"Stop"}"#))
        XCTAssertNil(HookEventRecord.decode(#"{"session_id":"not-a-uuid","hook_event_name":"Stop"}"#))
    }

    func testEveryNonTerminalLifecycleEventMeansLive() {
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            XCTAssertEqual(
                ComposerReadiness.applying(event, to: .unknown), .live,
                "\(event) should mean the session is up"
            )
        }
    }

    func testSessionEndMeansAbsent() {
        XCTAssertEqual(ComposerReadiness.applying("SessionEnd", to: .live), .absent)
    }

    /// A renamed or newly-added upstream event must not move readiness. Degrading to the
    /// previous value keeps a Claude Code release from silently changing the gate.
    func testUnknownEventNamesAreIgnored() {
        XCTAssertEqual(ComposerReadiness.applying("SomethingNew", to: .live), .live)
        XCTAssertEqual(ComposerReadiness.applying("SomethingNew", to: .unknown), .unknown)
    }

    /// A session that ended and then reported again is a resume, not a zombie.
    func testAnEventAfterSessionEndRevivesTheSession() {
        XCTAssertEqual(ComposerReadiness.applying("SessionStart", to: .absent), .live)
    }
}
