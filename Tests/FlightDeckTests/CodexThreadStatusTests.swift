import XCTest
@testable import FlightDeck

/// The one table both `CodexEventMapper` and `CodexAdapter.read` map thread status through.
///
/// Every case here is quoted from `ThreadStatus` / `ThreadActiveFlag` in the schema that
/// `codex app-server generate-json-schema` emits at codex-cli 0.147.0 — not from a doc
/// comment and not from a hand-written fixture. `CodexSchemaConformanceTests` re-asserts the
/// same vocabulary against the checked-in schema, so a codex release that drops or renames a
/// case fails there rather than silently here.
final class CodexThreadStatusTests: XCTestCase {
    func testIdleIsIdle() {
        XCTAssertEqual(CodexThreadStatus.activity(from: ["type": "idle"]), .idle)
    }

    func testActiveWithNoFlagsIsBusy() {
        // `active` is the only status that means the thread is working. The pre-fix code had
        // no case for it at all, so a working thread read as `.idle`.
        XCTAssertEqual(CodexThreadStatus.activity(from: ["type": "active", "activeFlags": []]), .busy)
    }

    func testActiveWithAnActiveFlagIsWaiting() {
        // `activeFlags` is the only place codex says "this thread is blocked on the user",
        // which is what `.waiting` exists to render.
        for flag in ["waitingOnApproval", "waitingOnUserInput"] {
            XCTAssertEqual(
                CodexThreadStatus.activity(from: ["type": "active", "activeFlags": [flag]]),
                .waiting, "\(flag) must read as waiting, not busy"
            )
        }
    }

    func testNotLoadedSaysNothing() {
        // Probed against a real app-server: `thread/read` on a thread that exists on disk
        // but is not open in this process SUCCEEDS with `notLoaded`. It is an absence of
        // information, not a claim that the thread is idle.
        XCTAssertNil(CodexThreadStatus.activity(from: ["type": "notLoaded"]))
    }

    func testSystemErrorRetiresTheSpinner() {
        XCTAssertEqual(CodexThreadStatus.activity(from: ["type": "systemError"]), .idle)
    }

    func testTheInventedVocabularyMapsToNothing() {
        // `running` and `busy` were never in the protocol. They are asserted here explicitly
        // so nobody reintroduces them believing they once worked.
        for invented in ["running", "busy", "inProgress", "someFutureState"] {
            XCTAssertNil(CodexThreadStatus.activity(from: ["type": invented]),
                         "\(invented) is not a ThreadStatus and must not pin an activity")
        }
    }

    func testAMissingOrMalformedStatusMapsToNothing() {
        XCTAssertNil(CodexThreadStatus.activity(from: nil))
        XCTAssertNil(CodexThreadStatus.activity(from: [:]))
        XCTAssertNil(CodexThreadStatus.activity(from: ["type": 7]))
    }
}
