import FleetKit
import XCTest
@testable import FlightDeckMobile

final class RoundFactsTests: XCTestCase {
    func testFourFactsAndDashesForWhatIsMissing() {
        let r = WireRound(checkpoint: 3, name: "Refine 1", code: "RF1", stage: "refine",
                          startedAt: Date(timeIntervalSinceReferenceDate: 0), landedAt: Date(timeIntervalSinceReferenceDate: 391),
                          outcome: "ok", changeCount: 41, linesAdded: 620, linesRemoved: 180,
                          verdicts: WireVerdicts(agreed: 33, somewhat: 6, declined: 2))
        let f = RoundFacts(r)
        XCTAssertEqual([f.time, f.changes, f.lines, f.verdicts], ["6:31", "41", "+620 −180", "33 · 6 · 2"])
        XCTAssertEqual(f.spoken, "6 minutes 31, 41 changes, 620 lines added and 180 removed, 33 agreed, 6 somewhat, 2 declined")

        let draft = WireRound(checkpoint: 1, name: "Drafts", code: "DRF", stage: "draft", startedAt: nil,
                              landedAt: Date(), outcome: "fallback", changeCount: nil, linesAdded: 0, linesRemoved: 0)
        let g = RoundFacts(draft)
        XCTAssertEqual([g.time, g.changes, g.verdicts], ["—", "—", "—"])
        XCTAssertTrue(g.spoken.contains("no duration recorded"))
        XCTAssertTrue(g.spoken.contains("no verdicts"))
        XCTAssertFalse(g.spoken.contains("—"), "VoiceOver hears words, never a dash")
    }
}
