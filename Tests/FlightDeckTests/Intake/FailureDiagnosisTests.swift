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
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "Error: not logged in", parseError: nil, harness: .claude)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `claude /login` in a terminal")
    }

    func testAuthExpiredOnUnauthorizedPicksCodexLoginFromHarnessParam() {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: Data(), stderr: "unauthorized: token expired", parseError: nil, harness: .codex)
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
                                           parseError: HarnessOutput.ParseError.notJSON("not json"))
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
}
