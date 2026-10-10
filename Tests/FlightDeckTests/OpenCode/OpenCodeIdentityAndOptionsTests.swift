import IntakeKit
import XCTest
@testable import FlightDeck

final class OpenCodeIdentityTests: XCTestCase {
    func testTheDerivedIDIsStableAndAVersion5UUID() {
        let a = OpenCodeIdentity.conversationID(forSession: "ses_ef6c9549fffeN3i4Mb4QHBuHGh")
        let b = OpenCodeIdentity.conversationID(forSession: "ses_ef6c9549fffeN3i4Mb4QHBuHGh")
        XCTAssertEqual(a, b, "the store and the search builder must derive the same id independently")
        let text = a.uuidString
        XCTAssertEqual(Array(text)[14], "5", "version nibble")
        XCTAssertTrue("89AB".contains(Array(text)[19]), "RFC 4122 variant")
    }

    func testDistinctSessionsGetDistinctIDs() {
        XCTAssertNotEqual(
            OpenCodeIdentity.conversationID(forSession: "ses_aaa"),
            OpenCodeIdentity.conversationID(forSession: "ses_aab")
        )
    }

    func testTheSessionIDRidesInTheMirrorFileName() {
        let url = URL(fileURLWithPath: "/x/mirror/abc/ses_ef6c9549fffeN3i4Mb4QHBuHGh.jsonl")
        XCTAssertEqual(OpenCodeIdentity.sessionID(fromTranscript: url), "ses_ef6c9549fffeN3i4Mb4QHBuHGh")
    }

    /// A codex rollout or a claude transcript handed here by mistake must not yield an id that
    /// would then be sent to an OpenCode server.
    func testOtherAgentsTranscriptsNameNoSession() {
        XCTAssertNil(OpenCodeIdentity.sessionID(fromTranscript: nil))
        XCTAssertNil(OpenCodeIdentity.sessionID(fromTranscript: URL(fileURLWithPath:
            "/Users/x/.codex/sessions/2026/10/rollout-2026-10-04T12-00-00-0199a.jsonl")))
        XCTAssertNil(OpenCodeIdentity.sessionID(fromTranscript: URL(fileURLWithPath:
            "/Users/x/.claude/projects/-a/8f1d2c3e-1111-2222-3333-444455556666.jsonl")))
        XCTAssertNil(OpenCodeIdentity.sessionID(fromTranscript: URL(fileURLWithPath: "/x/ses_abc.json")))
        XCTAssertNil(OpenCodeIdentity.sessionID(fromTranscript: URL(fileURLWithPath: "/x/ses_a b.jsonl")))
    }
}

final class OpenCodeOptionsTests: XCTestCase {
    /// Ollama model names carry slashes of their own; splitting at the last slash would send half
    /// the model name as the provider.
    func testTheModelSplitsAtTheFirstSlashOnly() {
        let options = OpenCodeOptions(model: "ollama/hf.co/org/model:Q4")
        XCTAssertEqual(options.modelReference?.providerID, "ollama")
        XCTAssertEqual(options.modelReference?.modelID, "hf.co/org/model:Q4")
    }

    func testAModelWithNoProviderIsNotSent() {
        XCTAssertNil(OpenCodeOptions(model: "qwen3-coder:32k").modelReference)
        XCTAssertNil(OpenCodeOptions(model: "/qwen").modelReference)
        XCTAssertNil(OpenCodeOptions(model: "ollama/").modelReference)
        XCTAssertNil(OpenCodeOptions().modelReference)
    }

    func testTheProjectWinsFieldByField() {
        let merged = OpenCodeOptions.merge(
            global: OpenCodeOptions(model: "ollama/a", agent: "plan"),
            project: OpenCodeOptions(model: "ollama/b")
        )
        XCTAssertEqual(merged, OpenCodeOptions(model: "ollama/b", agent: "plan"))
    }

    func testTheOptionsRoundTripThroughTheAgentsStorageFormat() throws {
        let options = AgentOptions.opencode(OpenCodeOptions(model: "ollama/qwen3-coder:32k", agent: "build"))
        let decoded = try JSONDecoder().decode(AgentOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        XCTAssertEqual(decoded.agent, .opencode)
    }

    func testEmptinessIsEveryFieldUnset() {
        XCTAssertTrue(AgentOptions.opencode(OpenCodeOptions()).isEmpty)
        XCTAssertFalse(AgentOptions.opencode(OpenCodeOptions(agent: "plan")).isEmpty)
    }
}

@MainActor
final class OpenCodeTurnRecoveryTests: XCTestCase {
    func testOnlyARetryableAPIErrorRetries() {
        let recovery = OpenCodeTurnRecovery()
        XCTAssertTrue(recovery.retries(.init(status: 503, kind: "APIError", isTransient: true)))
        XCTAssertFalse(recovery.retries(.init(status: 400, kind: "APIError", isTransient: false)))
        XCTAssertFalse(recovery.retries(.init(kind: "ProviderAuthError", isTransient: true)),
                       "only APIError carries OpenCode's own retryability verdict")
        XCTAssertFalse(recovery.retries(.init(kind: "ContextOverflowError")))
        XCTAssertFalse(recovery.retries(.init(kind: "SomeFutureError", isTransient: true)))
        XCTAssertEqual(recovery.resumeText, SessionStore.resumePrompt)
    }
}
