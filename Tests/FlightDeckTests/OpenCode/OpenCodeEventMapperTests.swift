import IntakeKit
import FleetKit
import XCTest
@testable import FlightDeck

/// `OpenCodeEventMapper` against `Fixtures/OpenCode/global-events.captured.jsonl` — the
/// `/global/event` stream of a real `opencode serve` 1.18.34 (deltas and heartbeats dropped),
/// driven through a permission request, a question, a slow turn and an abort.
final class OpenCodeEventMapperTests: XCTestCase {
    private func capturedLines() throws -> [String] {
        let text = try String(contentsOf: OpenCodeFixtures.url("global-events.captured", "jsonl"), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private func signals(_ type: String, _ properties: [String: Any]) -> [OpenCodeSignal] {
        OpenCodeEventMapper.signals(type: type, properties: properties, now: Date(timeIntervalSince1970: 1))
    }

    /// Every captured kind that matters is recognised, so a rename of an event type in a future
    /// OpenCode shows up here rather than as a tab that silently stops updating.
    func testTheCapturedStreamYieldsEverySignalKind() throws {
        let all = try capturedLines().flatMap { OpenCodeEventMapper.signals(inEventJSON: $0) }
        func any(_ match: (OpenCodeSignal) -> Bool) -> Bool { all.contains(where: match) }
        XCTAssertTrue(any { if case .activity(_, .busy) = $0 { true } else { false } })
        XCTAssertTrue(any { if case .activity(_, .idle) = $0 { true } else { false } })
        XCTAssertTrue(any { if case .activity(_, .waiting) = $0 { true } else { false } })
        XCTAssertTrue(any { if case .turnEnded = $0 { true } else { false } })
        XCTAssertTrue(any { if case .messageSettled = $0 { true } else { false } })
        XCTAssertTrue(any { if case .created = $0 { true } else { false } })
        XCTAssertTrue(any { if case .prompt(_, let l) = $0 { l.contains("prompt.asked") } else { false } })
        XCTAssertTrue(any { if case .prompt(_, let l) = $0 { l.contains("prompt.resolved") } else { false } })
    }

    /// `esc-abort-events.captured.jsonl`: a real turn against Ollama interrupted with Esc-Esc in
    /// an attached TUI. The person's interrupt and the phone's HTTP abort both arrive as
    /// `MessageAbortedError` — this is the person's half, captured.
    func testAnEscapeInTheTUIIsAnAbortThenTheTurnEnding() throws {
        let text = try String(contentsOf: OpenCodeFixtures.url("esc-abort-events.captured", "jsonl"), encoding: .utf8)
        let all = text.split(separator: "\n").flatMap { OpenCodeEventMapper.signals(inEventJSON: String($0)) }
        let aborted = try XCTUnwrap(all.firstIndex(of: .turnAborted(session: "ses_ef918c5fbffeeD65m5R3oGVvuh")))
        let ended = try XCTUnwrap(all.firstIndex(of: .turnEnded(session: "ses_ef918c5fbffeeD65m5R3oGVvuh")))
        XCTAssertLessThan(aborted, ended)
        XCTAssertFalse(all.contains { if case .apiError = $0 { true } else { false } },
                       "an interrupt must never arm the API-error retry ladder")
    }

    func testStatusKinds() {
        XCTAssertEqual(signals("session.status", ["sessionID": "ses_a", "status": ["type": "busy"]]),
                       [.activity(session: "ses_a", .busy)])
        XCTAssertEqual(signals("session.status", ["sessionID": "ses_a", "status": ["type": "idle"]]),
                       [.activity(session: "ses_a", .idle)])
        // OpenCode retrying the provider itself is a turn still in flight — never an error the
        // store's own retry ladder should also act on.
        XCTAssertEqual(
            signals("session.status", ["sessionID": "ses_a", "status":
                ["type": "retry", "attempt": 1, "message": "Provider response headers timed out", "next": 5]]),
            [.activity(session: "ses_a", .busy)]
        )
    }

    func testIdleEndsTheTurn() {
        XCTAssertEqual(signals("session.idle", ["sessionID": "ses_a"]),
                       [.activity(session: "ses_a", .idle), .turnEnded(session: "ses_a")])
    }

    func testAnAbortIsNotAnAPIError() {
        XCTAssertEqual(
            signals("session.error", ["sessionID": "ses_a",
                                      "error": ["name": "MessageAbortedError", "data": ["message": "Aborted"]]]),
            [.turnAborted(session: "ses_a")]
        )
    }

    func testAnAPIErrorCarriesStatusAndRetryability() {
        XCTAssertEqual(
            signals("session.error", ["sessionID": "ses_a", "error": ["name": "APIError",
                "data": ["message": "overloaded", "statusCode": 529, "isRetryable": true]]]),
            [.apiError(session: "ses_a", SessionAPIError(status: 529, kind: "APIError", isTransient: true))]
        )
        XCTAssertEqual(
            signals("session.error", ["sessionID": "ses_a", "error": ["name": "ProviderAuthError",
                "data": ["message": "no key", "providerID": "x"]]]),
            [.apiError(session: "ses_a", SessionAPIError(kind: "ProviderAuthError", isTransient: false))]
        )
    }

    /// OpenCode's placeholder title would rename a tab to a timestamp.
    func testThePlaceholderTitleIsNotForwarded() {
        XCTAssertEqual(
            signals("session.updated", ["info": ["id": "ses_a", "title": "New session - 2026-10-04T12:32:59.154Z"]]),
            []
        )
        XCTAssertEqual(signals("session.updated", ["info": ["id": "ses_a", "title": "Fix the parser"]]),
                       [.title(session: "ses_a", "Fix the parser")])
    }

    func testACreatedChildNamesItsParent() {
        XCTAssertEqual(
            signals("session.created", ["info": ["id": "ses_child", "parentID": "ses_root",
                                                 "title": "Explore (@explore subagent)"]]),
            [.created(session: "ses_child", parent: "ses_root"),
             .title(session: "ses_child", "Explore (@explore subagent)")]
        )
    }

    func testOnlySettledMessagesTriggerAMirrorSync() {
        XCTAssertEqual(signals("message.updated", ["info": ["sessionID": "ses_a", "role": "user"]]),
                       [.messageSettled(session: "ses_a")])
        XCTAssertEqual(signals("message.updated", ["info": ["sessionID": "ses_a", "role": "assistant",
                                                            "time": ["created": 1]]]), [])
        XCTAssertEqual(signals("message.updated", ["info": ["sessionID": "ses_a", "role": "assistant",
                                                            "time": ["created": 1, "completed": 2]]]),
                       [.messageSettled(session: "ses_a")])
    }

    func testAPermissionRequestBecomesAWaitingTabAndAMirrorRecord() throws {
        let out = signals("permission.asked", [
            "id": "per_1", "sessionID": "ses_a", "permission": "bash", "patterns": ["ls"],
            "metadata": ["command": "ls"], "always": ["ls *"],
            "tool": ["messageID": "msg_1", "callID": "call_1"],
        ])
        XCTAssertEqual(out.first, .activity(session: "ses_a", .waiting))
        guard case .prompt(let session, let line) = out.last else { return XCTFail("no record") }
        XCTAssertEqual(session, "ses_a")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["type"] as? String, "prompt.asked")
        XCTAssertEqual(record["id"] as? String, "per_1", "the REQUEST id is what the reply endpoint takes")
        XCTAssertEqual(record["permission"] as? String, "bash")
    }

    func testAReplyReleasesTheTurn() throws {
        let out = signals("permission.replied", ["sessionID": "ses_a", "requestID": "per_1", "reply": "reject"])
        XCTAssertEqual(out.first, .activity(session: "ses_a", .busy))
        guard case .prompt(_, let line) = out.last else { return XCTFail() }
        XCTAssertTrue(line.contains(#""outcome":"reject""#))
        XCTAssertTrue(line.contains(#""type":"prompt.resolved""#))
    }

    func testTheStreamDropsDeltasBeforeDecodingThem() {
        XCTAssertNil(OpenCodeEventStream.batch(fromLine:
            #"data: {"payload":{"type":"message.part.delta","properties":{"sessionID":"ses_a"}}}"#))
        XCTAssertNil(OpenCodeEventStream.batch(fromLine: ": keepalive"))
        let batch = OpenCodeEventStream.batch(fromLine:
            #"data: {"directory":"/w","payload":{"type":"session.idle","properties":{"sessionID":"ses_a"}}}"#)
        XCTAssertEqual(batch?.directory, "/w")
        XCTAssertEqual(batch?.signals.last, .turnEnded(session: "ses_a"))
    }
}
