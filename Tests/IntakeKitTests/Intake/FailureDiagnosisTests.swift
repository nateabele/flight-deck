import XCTest
import IntakeKit

final class FailureDiagnosisTests: XCTestCase {
    func testRateLimitedOnRateLimitPhrase() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Error: Rate limit exceeded, try again later", parseError: nil)
        XCTAssertEqual(d.category, .rateLimited)
        XCTAssertEqual(d.action, "Wait for the limit to reset, or switch this slot to another model.")
    }

    func testRateLimitedOn429() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "HTTP 429 Too Many Requests", parseError: nil)
        XCTAssertEqual(d.category, .rateLimited)
    }

    func testRateLimitedOnUsageLimitCaseInsensitive() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "You have hit your USAGE LIMIT for this plan", parseError: nil)
        XCTAssertEqual(d.category, .rateLimited)
    }

    func testAuthExpiredOnNotLoggedIn() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Error: not logged in", parseError: nil, agent: .claude)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `claude /login` in a terminal")
    }

    func testAuthExpiredOnUnauthorizedPicksCodexLoginFromHarnessParam() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "unauthorized: token expired", parseError: nil, agent: .codex)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `codex login` in a terminal")
    }

    func testAuthExpiredOn401WithoutHarnessDefaultsToClaudeLogin() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "server responded 401", parseError: nil)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `claude /login` in a terminal")
    }

    func testAuthExpiredOnAuthenticationWord() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Authentication failed", parseError: nil)
        XCTAssertEqual(d.category, .authExpired)
    }

    func testAuthExpiredOnClaudeLoginPhraseInferHarness() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Please run `claude /login`", parseError: nil)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `claude /login` in a terminal")
    }

    func testAuthExpiredOnCodexLoginPhraseInferHarness() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Not authenticated. Please run `codex login`", parseError: nil)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `codex login` in a terminal")
    }

    func testTimeoutOnExitCode124() {
        let d = FailureDiagnosis.classify(exitCode: 124, stdout: Data(), stderr: "", parseError: nil)
        XCTAssertEqual(d.category, .timeout)
        XCTAssertEqual(d.action, "Retry the round.")
    }

    func testTimeoutOnStderrPhrase() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "operation timed out after 300s", parseError: nil)
        XCTAssertEqual(d.category, .timeout)
        XCTAssertEqual(d.action, "Retry the round.")
    }

    func testInvalidOutputOnExitZeroWithParseError() {
        let d = FailureDiagnosis.classify(exitCode: 0, stdout: Data("not json".utf8), stderr: "",
                                           parseError: HeadlessOutput.ParseError.notJSON("not json"))
        XCTAssertEqual(d.category, .invalidOutput)
        XCTAssertEqual(d.action, "The model returned something other than the schema — retry, or switch this slot's model.")
    }

    func testHarnessErrorFallsThroughToLastThreeStderrLines() {
        let stderr = "line one\nline two\nline three\nline four\nline five"
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: stderr, parseError: nil)
        XCTAssertEqual(d.category, .harnessError)
        XCTAssertEqual(d.detail, "line three\nline four\nline five")
        XCTAssertEqual(d.action, "Retry, or change this slot.")
    }

    func testHarnessErrorIsTheFallbackForAnUnmatchedNonzeroExit() {
        let d = FailureDiagnosis.classify(exitCode: 2, stdout: Data(), stderr: "some unrelated failure", parseError: nil)
        XCTAssertEqual(d.category, .harnessError)
    }

    // MARK: - Only stderr and structured error events count

    /// The agent's own words are not a diagnosis: a drafter whose plan discusses "401
    /// authentication" and then dies must read as the crash it was, not send the human off to
    /// log in again.
    func testAgentTextInStdoutNeverClassifies() {
        let started = #"{"type":"thread.started","thread_id":"T"}"#
        let message = #"{"type":"item.completed","item":{"type":"agent_message","text":"Handle 401 authentication and rate limit errors"}}"#
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data((started + "\n" + message).utf8),
                                           stderr: "", parseError: nil, agent: .codex)
        XCTAssertEqual(d.category, .harnessError)
    }

    func testCodexErrorEventClassifies() {
        let out = #"{"type":"thread.started","thread_id":"T"}"# + "\n" + #"{"type":"error","message":"unexpected status 401 Unauthorized"}"#
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(out.utf8), stderr: "", parseError: nil, agent: .codex)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `codex login` in a terminal")
        XCTAssertEqual(d.detail, "unexpected status 401 Unauthorized")
    }

    func testCodexTurnFailedEventClassifies() {
        let out = #"{"type":"turn.failed","error":{"message":"You've hit your usage limit."}}"#
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(out.utf8), stderr: "", parseError: nil, agent: .codex)
        XCTAssertEqual(d.category, .rateLimited)
    }

    func testClaudeIsErrorResultClassifies() {
        let out = #"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login","session_id":"S"}"#
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(out.utf8), stderr: "", parseError: nil, agent: .claude)
        XCTAssertEqual(d.category, .authExpired)
    }

    /// Under stream-json the `is_error` result is the LAST of many lines, not the whole stdout.
    func testClaudeStreamIsErrorResultClassifies() {
        let out = #"{"type":"system","subtype":"init","session_id":"S"}"# + "\n"
            + #"{"type":"assistant","message":{"content":[{"type":"text","text":"401 is an HTTP status"}]}}"# + "\n"
            + #"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login","session_id":"S"}"# + "\n"
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(out.utf8), stderr: "", parseError: nil, agent: .claude)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.detail, "Invalid API key · Please run /login")
        let fine = out.replacingOccurrences(of: #""is_error":true"#, with: #""is_error":false"#)
        XCTAssertEqual(FailureDiagnosis.classify(exitCode: 1, stdout: Data(fine.utf8), stderr: "", parseError: nil,
                                                 agent: .claude).category, .harnessError)
    }

    /// A successful claude result is the model's answer, however it is worded.
    func testClaudeResultWithoutIsErrorNeverClassifies() {
        let out = #"{"type":"result","is_error":false,"result":"The API returns 429 when rate limited","session_id":"S"}"#
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(out.utf8), stderr: "", parseError: nil, agent: .claude)
        XCTAssertEqual(d.category, .harnessError)
    }

    /// The END of the text is where a CLI says why it died; a long stderr's opening lines are
    /// banners and warnings.
    func testDetailIsTheEndOfTheText() {
        let stderr = String(repeating: "warning: noise\n", count: 40) + "error: 401 Unauthorized"
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: stderr, parseError: nil)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertTrue(d.detail.hasSuffix("error: 401 Unauthorized"), d.detail)
        XCTAssertLessThanOrEqual(d.detail.count, 200)
    }

    /// With nothing on stderr, the error event is what the human reads.
    func testHarnessErrorFallsBackToTheErrorEvent() {
        let out = #"{"type":"turn.failed","error":{"message":"stream disconnected before completion"}}"#
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(out.utf8), stderr: "", parseError: nil, agent: .codex)
        XCTAssertEqual(d.category, .harnessError)
        XCTAssertEqual(d.detail, "stream disconnected before completion")
    }
}
