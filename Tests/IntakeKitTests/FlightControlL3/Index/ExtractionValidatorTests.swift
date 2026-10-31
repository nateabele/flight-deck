import XCTest
import IntakeKit

/// The index only ever believes a figure it can cite. These tests run the validator over
/// recorded agent answers and pin the three rejections the spec names — no url, a quoted
/// figure that is not the score, an unknown unit — plus the two that would otherwise let a row
/// in under false pretences: a unit other than the source's, and an answer for another source.
final class ExtractionValidatorTests: XCTestCase {
    private var terminalBench: IndexSource { IndexSourceRegistry.initial.first { $0.id == "terminal-bench" }! }

    func testRecordedValidOutputIsAcceptedWhole() throws {
        let result = ExtractionValidator.validate(try IndexFixtures.payload("extraction-valid"), for: terminalBench)
        XCTAssertEqual(result.rejected, [])
        XCTAssertEqual(result.accepted.map(\.benchmarkModel), ["GPT-6 Sol (high)", "Opus 5 (high)", "Sonnet 5"])
        XCTAssertEqual(result.accepted.first?.unit, .percent)
        XCTAssertEqual(result.accepted.first?.url, "https://www.tbench.ai/leaderboard")
    }

    func testRecordedMixedOutputRejectsEachBadRowWithItsReason() throws {
        let result = ExtractionValidator.validate(try IndexFixtures.payload("extraction-mixed"), for: terminalBench)
        XCTAssertEqual(result.accepted.map(\.benchmarkModel), ["GPT-6 Sol (high)"])
        XCTAssertEqual(result.rejected.map(\.reason), [
            "missing url",
            "quoted figure \"17.0%\" does not match score 71.0",
            "unknown unit stars",
            "unit elo but terminal-bench reads percent",
            "missing url"])
    }

    func testAnAnswerForAnotherSourceIsRejectedWhole() throws {
        var payload = try IndexFixtures.payload("extraction-valid")
        payload.source = "aider-polyglot"
        let result = ExtractionValidator.validate(payload, for: terminalBench)
        XCTAssertEqual(result.accepted, [])
        XCTAssertEqual(Set(result.rejected.map(\.reason)), ["payload is for aider-polyglot, not terminal-bench"])
    }

    func testFigureParsing() {
        XCTAssertTrue(ExtractionValidator.figureMatches("61.3%", score: 61.3))
        XCTAssertTrue(ExtractionValidator.figureMatches("61.3%", score: 61.33), "within half the quoted precision")
        XCTAssertFalse(ExtractionValidator.figureMatches("61.3%", score: 61.36))
        XCTAssertTrue(ExtractionValidator.figureMatches("1,234 Elo", score: 1234))
        XCTAssertTrue(ExtractionValidator.figureMatches("$3.00 / 1M tokens", score: 3))
        XCTAssertTrue(ExtractionValidator.figureMatches("0.42s", score: 0.42))
        XCTAssertFalse(ExtractionValidator.figureMatches("about sixty", score: 60))
        XCTAssertFalse(ExtractionValidator.figureMatches("61.3%", score: 0.613), "a fraction is not the percent it was quoted as")
        XCTAssertNil(ExtractionValidator.parseFigure(""))
        XCTAssertEqual(ExtractionValidator.parseFigure("49.75 %")?.decimals, 2)
    }
}
