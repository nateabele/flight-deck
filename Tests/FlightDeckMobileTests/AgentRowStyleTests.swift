import FleetKit
import XCTest
@testable import FlightDeckMobile

final class AgentRowStyleTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func agent(glyph: String = "running", last: TimeInterval? = 0, rateLimited: TimeInterval? = nil,
                       fallback: String? = nil, failure: String? = nil, action: String? = "Reading a.swift") -> WireAgent {
        WireAgent(id: "r", glyph: glyph, role: "reviewer", identity: "codex · gpt-6-sol · high", action: action,
                  startedAt: t0, lastEventAt: last.map { t0.addingTimeInterval($0) },
                  rateLimitedAt: rateLimited.map { t0.addingTimeInterval($0) }, fallback: fallback, failure: failure)
    }

    func testQuietThenStalled() {
        XCTAssertNil(AgentRowStyle.exception(agent(), now: t0.addingTimeInterval(29)))
        XCTAssertEqual(AgentRowStyle.exception(agent(), now: t0.addingTimeInterval(34)), .quiet(34))
        XCTAssertEqual(AgentRowStyle.exception(agent(), now: t0.addingTimeInterval(105)), .stalled(105, last: "Reading a.swift"))
    }

    func testPrecedenceMatchesTheMac() {
        XCTAssertEqual(AgentRowStyle.exception(agent(rateLimited: 10), now: t0.addingTimeInterval(200)), .rateLimited(190))
        XCTAssertEqual(AgentRowStyle.exception(agent(fallback: "fell back to codex · claude 401"), now: t0.addingTimeInterval(40)),
                       .fallback("fell back to codex · claude 401"))
        XCTAssertEqual(AgentRowStyle.exception(agent(fallback: "x"), now: t0.addingTimeInterval(95)), .stalled(95, last: "Reading a.swift"))
    }

    func testAFinishedRowHasOnlyItsFailure() {
        XCTAssertNil(AgentRowStyle.exception(agent(glyph: "done"), now: t0.addingTimeInterval(500)))
        XCTAssertEqual(AgentRowStyle.exception(agent(glyph: "failed", failure: "exit 1"), now: t0.addingTimeInterval(500)), .failed("exit 1"))
    }

    func testExceptionWords() {
        XCTAssertEqual(AgentRowStyle.exceptionText(.quiet(34)), "quiet 0:34")
        XCTAssertEqual(AgentRowStyle.exceptionText(.stalled(105, last: "Running swift build")), "No output for 1:45 · last: Running swift build")
        XCTAssertEqual(AgentRowStyle.exceptionText(.rateLimited(42)), "Waiting on rate limit · 0:42")
        XCTAssertFalse(AgentRowStyle.isAmber(.quiet(34)))
        XCTAssertTrue(AgentRowStyle.isAmber(.stalled(95, last: nil)))
    }
}
