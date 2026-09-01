// Tests/FlightDeckTests/NameMatcherTests.swift
import XCTest
import FleetKit
@testable import FlightDeck

/// Scoring one name against a typed query.
///
/// Tiers, not a single blended score: an exact match and a loose subsequence match are
/// different *kinds* of answer, and collapsing them into one number is what makes a search
/// list feel arbitrary. `SearchRanker` orders by tier first and recency second.
final class NameMatcherTests: XCTestCase {
    func testAnExactMatchIsTheTopTier() {
        XCTAssertEqual(NameMatcher.score("rename-break", against: "rename-break")?.tier, .exact)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(NameMatcher.score("Rename-Break", against: "rename-break")?.tier, .exact)
        XCTAssertEqual(NameMatcher.score("rename-break", against: "RENAME")?.tier, .prefix)
    }

    func testAPrefixOutranksAFuzzyMatch() {
        let prefix = NameMatcher.score("rename-break", against: "rename")
        let fuzzy = NameMatcher.score("rename-break", against: "rnmbk")

        XCTAssertEqual(prefix?.tier, .prefix)
        XCTAssertEqual(fuzzy?.tier, .fuzzy)
        XCTAssertLessThan(prefix!.tier, fuzzy!.tier)
    }

    /// Subsequence matching is the whole point of "fuzzy": the characters appear in order
    /// but not adjacently, which is how people type abbreviations.
    func testCharactersMatchingInOrderButNotAdjacentlyAreAFuzzyMatch() {
        XCTAssertEqual(NameMatcher.score("session-menu", against: "ssnmn")?.tier, .fuzzy)
    }

    func testCharactersOutOfOrderDoNotMatch() {
        XCTAssertNil(NameMatcher.score("session-menu", against: "unem"))
    }

    func testAQueryLongerThanTheCandidateCannotMatch() {
        XCTAssertNil(NameMatcher.score("wifi", against: "wifi-network"))
    }

    /// The ranges the row underlines. Without them a fuzzy hit looks like it matched
    /// nothing, which reads as a bug.
    func testMatchedRangesCoverEveryQueryCharacter() {
        let match = NameMatcher.score("session-menu", against: "smenu")
        let matched = match?.matchedRanges.map { String("session-menu"[$0]) }.joined()

        XCTAssertEqual(matched, "smenu")
    }

    func testAnExactMatchHighlightsTheWholeName() {
        let match = NameMatcher.score("wifi", against: "wifi")
        XCTAssertEqual(match?.matchedRanges.count, 1)
        XCTAssertEqual(match.map { String("wifi"[$0.matchedRanges[0]]) }, "wifi")
    }

    /// An empty query is the empty-query state, which lists recent sessions rather than
    /// matching. It must not report every name as a match.
    func testAnEmptyQueryMatchesNothing() {
        XCTAssertNil(NameMatcher.score("anything", against: ""))
    }

    /// A one-character query subsequence-matches almost every name, which would bury the
    /// exact and prefix hits under noise on the very first keystroke.
    func testASingleCharacterQueryOnlyMatchesAsAPrefix() {
        XCTAssertEqual(NameMatcher.score("rename-break", against: "r")?.tier, .prefix)
        XCTAssertNil(NameMatcher.score("session-menu", against: "r"))
        // 'e' occurs in "session-menu" and is not its first character, so it would fuzzy-match
        // if the floor were removed — which is what makes this assertion a guard on the floor
        // rather than on the subsequence walk.
        XCTAssertNil(NameMatcher.score("session-menu", against: "e"))
    }

    func testTheFuzzyFloorRejectsTwoCharactersAndAcceptsThree() {
        // Both occur as in-order subsequences of "session-menu"; only the length differs.
        XCTAssertNil(NameMatcher.score("session-menu", against: "sn"))
        XCTAssertEqual(NameMatcher.score("session-menu", against: "ssn")?.tier, .fuzzy)
    }
}
