import XCTest
@testable import FlightDeck

/// The order results come back in.
///
/// Two rules, in this order: match quality tiers the list, and within a tier the most
/// recently active thing wins. Scores are never compared across tiers — a BM25 score and a
/// fuzzy-subsequence score are not on the same scale.
final class SearchRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func session(
        _ name: String, project: String = "flight-deck", activity: TimeInterval
    ) -> NameCandidate {
        NameCandidate(
            id: name, kind: .session(UUID()), name: name,
            projectPath: "/w/\(project)", projectName: project,
            lastActivity: ago(activity), conversationID: nil
        )
    }

    private func project(_ name: String, activity: TimeInterval) -> NameCandidate {
        NameCandidate(
            id: "project-\(name)", kind: .project, name: name,
            projectPath: "/w/\(name)", projectName: name,
            lastActivity: ago(activity), conversationID: nil
        )
    }

    private func hit(
        _ conversation: String, snippet: String, activity: TimeInterval, rowID: Int64 = 1
    ) -> TranscriptHit {
        TranscriptHit(
            rowID: rowID, conversationID: conversation, projectPath: "/w/flight-deck",
            conversationName: conversation, snippet: snippet, timestamp: ago(activity)
        )
    }

    /// The headline rule. An exact match that is weeks old still beats a fuzzy match from a
    /// minute ago, because quality tiers the list before recency touches it.
    func testTierBeatsRecency() {
        let results = SearchRanker.rank(
            names: [
                session("re-name-me", activity: 60),       // fuzzy, one minute old
                session("rename", activity: 60 * 60 * 24 * 30), // exact, a month old
            ],
            query: "rename",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.title), ["rename", "re-name-me"])
    }

    /// The rule the user chose: within one tier, the thing touched most recently wins.
    func testRecencyOrdersWithinATier() {
        let results = SearchRanker.rank(
            names: [
                session("rename-old", activity: 60 * 60 * 24),
                session("rename-new", activity: 60),
            ],
            query: "rename",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.title), ["rename-new", "rename-old"])
    }

    /// "Prioritizes session and project names" is a hard rule, not a nudge: no transcript
    /// hit, however fresh or however well it matches, may outrank any name match.
    func testNoTranscriptHitOutranksAnyNameMatch() {
        let results = SearchRanker.rank(
            names: [session("re-name-me", activity: 60 * 60 * 24 * 365)],  // fuzzy, a year old
            query: "rename",
            transcripts: [hit("mobile-ui", snippet: "the rename bug", activity: 1)]
        )

        XCTAssertEqual(results.first?.title, "re-name-me")
        XCTAssertEqual(results.last?.kind, .conversation("mobile-ui"))
    }

    /// Sessions before projects at equal tier: the deck is session-centric and activating a
    /// result opens a session, so a session is the more likely intent.
    func testSessionsRankAboveProjectsAtTheSameTier() {
        let results = SearchRanker.rank(
            names: [
                project("rename", activity: 1),          // more recent
                session("rename", activity: 60 * 60),
            ],
            query: "rename",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.kind), [.session(results[0].kindSessionID!), .project])
    }

    /// Transcript hits carry the FTS5 snippet; name matches carry highlight ranges. The row
    /// draws one or the other, so a result must never arrive with neither.
    func testTranscriptHitsCarryASnippetAndNameMatchesCarryRanges() {
        let results = SearchRanker.rank(
            names: [session("rename-break", activity: 1)],
            query: "rename",
            transcripts: [hit("mobile-ui", snippet: "don't fire a rename", activity: 2)]
        )

        XCTAssertNil(results[0].snippet)
        XCTAssertFalse(results[0].highlightedRanges.isEmpty)
        XCTAssertEqual(results[1].snippet, "don't fire a rename")
        XCTAssertTrue(results[1].highlightedRanges.isEmpty)
    }

    func testNamesThatDoNotMatchAreExcluded() {
        let results = SearchRanker.rank(
            names: [session("wifi", activity: 1), session("rename", activity: 2)],
            query: "rename",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.title), ["rename"])
    }

    /// The empty-query state: every session, most recent first, so ⌘K-Return returns you to
    /// what you were just doing. Projects and transcript hits stay out — an empty query has
    /// nothing for FTS5 to match, and a list of every project is not what that gesture means.
    func testAnEmptyQueryListsSessionsByRecency() {
        let results = SearchRanker.rank(
            names: [
                session("older", activity: 60 * 60),
                project("a-project", activity: 1),
                session("newer", activity: 60),
            ],
            query: "",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.title), ["newer", "older"])
    }

    /// Ordering must be total. Two candidates identical in tier and timestamp would
    /// otherwise sort unstably, and a list that reshuffles between identical keystrokes is
    /// exactly the jitter the panel's stable-selection property is meant to prevent.
    func testOrderingIsDeterministicWhenTierAndRecencyTie() {
        let stamp: TimeInterval = 60
        let first = SearchRanker.rank(
            names: [session("rename-a", activity: stamp), session("rename-b", activity: stamp)],
            query: "rename", transcripts: []
        )
        let second = SearchRanker.rank(
            names: [session("rename-b", activity: stamp), session("rename-a", activity: stamp)],
            query: "rename", transcripts: []
        )

        XCTAssertEqual(first.map(\.title), second.map(\.title))
    }
}

private extension SearchResult {
    /// Test-only reach into the associated value, so the session-vs-project assertion above
    /// can be written without spelling out a UUID it does not care about.
    var kindSessionID: UUID? {
        if case .session(let id) = kind { return id }
        return nil
    }
}
