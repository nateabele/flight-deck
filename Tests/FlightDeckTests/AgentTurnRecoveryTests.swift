import XCTest
import IntakeKit
@testable import FlightDeck
@testable import FleetKit

@MainActor
final class AgentTurnRecoveryTests: XCTestCase {
    func testClaudeDefersToTheCLIsOwnPredicate() {
        let r = ClaudeTurnRecovery()
        XCTAssertTrue(r.retries(SessionAPIError(kind: "overloaded", isTransient: true)))
        XCTAssertFalse(r.retries(SessionAPIError(kind: "invalid_request", isTransient: false)))
    }

    func testCodexRetriesEveryAllowlistedKind() {
        let r = CodexTurnRecovery()
        for kind in ["rate_limit_exceeded", "server_overloaded", "internal_server_error",
                     "response_too_many_failed_attempts", "response_stream_connection_failed",
                     "response_stream_disconnected", "http_connection_failed"] {
            XCTAssertTrue(r.retries(SessionAPIError(kind: kind)), "\(kind) should retry")
        }
    }

    func testCodexRefusesPermanentKinds() {
        let r = CodexTurnRecovery()
        for kind in ["unauthorized", "bad_request", "context_window_exceeded",
                     "usage_limit_exceeded", "cyber_policy",
                     "misalignment_policy_violation", "sandbox_error", "other"] {
            XCTAssertFalse(r.retries(SessionAPIError(kind: kind)), "\(kind) must not retry")
        }
    }

    /// The fail-closed assertion, and the reason the allowlist exists. Codex's error
    /// vocabulary is not ours and it will grow; a kind we have never seen must never be
    /// able to cause unattended typing into a terminal.
    func testCodexRefusesAnUnknownKindAndANilKind() {
        let r = CodexTurnRecovery()
        XCTAssertFalse(r.retries(SessionAPIError(kind: "quantum_flux_exceeded")))
        XCTAssertFalse(r.retries(SessionAPIError(kind: nil)))
        // isTransient must NOT be a backdoor around the allowlist for codex.
        XCTAssertFalse(r.retries(SessionAPIError(kind: "quantum_flux", isTransient: true)))
    }

    func testBothAgentsExposeRecoveryThroughTheAgentIDSwitch() {
        XCTAssertNotNil(AgentID.claude.turnRecovery)
        XCTAssertNotNil(AgentID.codex.turnRecovery)
        XCTAssertEqual(AgentID.claude.turnRecovery?.resumeText, SessionStore.resumePrompt)
    }
}
