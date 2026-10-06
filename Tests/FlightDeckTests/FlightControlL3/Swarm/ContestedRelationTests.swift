import XCTest
import IntakeKit

/// Spec §7.5: contested is a relation, not a status — an agent is contested when it has a recent
/// guard block, or when it said BLOCKED: on a file another agent holds.
final class ContestedRelationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let held = [HeldReservation(pattern: "Sources/*.swift", holder: "GreenFox",
                                        since: Date(timeIntervalSince1970: 1_790_000_000 - 360))]
    private let block = GuardBlock(file: "Sources/Foo.swift", pattern: "Sources/*.swift", holder: "GreenFox",
                                   message: "mcp-agent-mail: file reservation conflict detected! Sources/Foo.swift conflicts with reservation 'Sources/*.swift' held by GreenFox")

    func testARecentGuardBlockIsAContestNamingTheHolderAndSince() {
        let c = ContestedRelation.contest(agent: "BlueLake",
                                          signals: SessionSignals(guardBlock: block, guardBlockAt: now - 30),
                                          reservations: held, now: now)
        XCTAssertEqual(c, Contest(file: "Sources/Foo.swift", holder: "GreenFox", heldSince: held[0].since,
                                  message: block.message, at: now - 30))
    }

    func testAnOldGuardBlockIsNotAContest() {
        XCTAssertNil(ContestedRelation.contest(agent: "BlueLake",
                                               signals: SessionSignals(guardBlock: block, guardBlockAt: now - 601),
                                               reservations: held, now: now))
    }

    func testAGuardBlockWorksWithoutReservationRows() {
        let c = ContestedRelation.contest(agent: "BlueLake", signals: SessionSignals(guardBlock: block, guardBlockAt: now),
                                          reservations: [], now: now)
        XCTAssertEqual(c?.holder, "GreenFox")
        XCTAssertNil(c?.heldSince)
    }

    func testBlockedOnAFileAnotherAgentHolds() {
        let c = ContestedRelation.contest(agent: "BlueLake",
                                          signals: SessionSignals(blocked: "need Sources/Foo.swift, it is reserved", blockedAt: now),
                                          reservations: held, now: now)
        XCTAssertEqual(c?.file, "Sources/Foo.swift")
        XCTAssertEqual(c?.holder, "GreenFox")
        XCTAssertEqual(c?.message, "BLOCKED: need Sources/Foo.swift, it is reserved")
    }

    func testBlockedOnSomethingElseIsNotContested() {
        XCTAssertNil(ContestedRelation.contest(agent: "BlueLake",
                                               signals: SessionSignals(blocked: "the API key is missing", blockedAt: now),
                                               reservations: held, now: now))
    }

    func testAnAgentIsNeverContestedByItself() {
        XCTAssertNil(ContestedRelation.contest(agent: "GreenFox",
                                               signals: SessionSignals(blocked: "Sources/Foo.swift", blockedAt: now),
                                               reservations: held, now: now))
    }

    func testGlob() {
        XCTAssertTrue(Glob.matches("Sources/*.swift", "Sources/Foo.swift"))
        XCTAssertFalse(Glob.matches("Sources/*.swift", "Sources/Sub/Foo.swift"))
        XCTAssertTrue(Glob.matches("Sources/**", "Sources/Sub/Foo.swift"))
        XCTAssertTrue(Glob.matches("a?.c", "ab.c"))
        XCTAssertTrue(Glob.matches("x.swift", "x.swift"))
        XCTAssertFalse(Glob.matches("x.swift", "xxswift"), "a dot is literal")
    }

    func testHeldReservationCoversByExactPathOrGlob() {
        let r = HeldReservation(pattern: "Sources/*.swift", holder: "GreenFox", since: nil)
        XCTAssertTrue(r.covers(file: "Sources/Foo.swift"))
        XCTAssertFalse(r.covers(file: "Tests/Foo.swift"))
        XCTAssertTrue(HeldReservation(pattern: "a.swift", holder: "X", since: nil).covers(file: "a.swift"))
    }
}
