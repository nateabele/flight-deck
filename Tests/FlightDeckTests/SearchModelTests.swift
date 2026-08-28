import XCTest
@testable import FlightDeck

/// An index that answers instantly and records what it was asked, so the model's
/// debouncing and merging can be tested without SQLite or sleeping.
private final class StubSearchIndex: SearchIndex {
    var hits: [TranscriptHit] = []
    private(set) var queries: [String] = []

    func ingest(_: [IndexedMessage], from: URL, projectPath: String, offset: UInt64?) throws {}
    func readOffset(for: URL) -> UInt64 { 0 }
    func conversationNames() throws -> [String: IndexedConversation] { [:] }
    func setConversationName(_: String, projectPath: String, for: String) throws {}
    func prune(keepingSources: Set<URL>, projects: Set<String>) throws {}
    func messageCount(forConversation: String) throws -> Int { 0 }

    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit] {
        queries.append(query)
        return hits
    }
}

/// What the overlay binds to.
@MainActor
final class SearchModelTests: XCTestCase {
    private var index: StubSearchIndex!
    private var model: SearchModel!

    private func candidate(_ name: String, activity: TimeInterval = 0) -> NameCandidate {
        NameCandidate(
            id: name, kind: .session(UUID()), name: name,
            projectPath: "/w/fd", projectName: "fd",
            lastActivity: Date(timeIntervalSince1970: 1_800_000_000 + activity),
            conversationID: nil
        )
    }

    override func setUp() async throws {
        index = StubSearchIndex()
        model = SearchModel(index: index, projects: { ["/w/fd"] })
        model.candidatesChanged([
            candidate("rename-break", activity: 100),
            candidate("session-menu", activity: 50),
            candidate("wifi", activity: 10),
        ])
    }

    /// Names are matched in memory with no I/O, so they must be on screen before any
    /// debounce elapses — that is the whole reason the two halves are split.
    func testNameResultsAppearSynchronouslyOnTyping() {
        model.query = "rename"

        XCTAssertEqual(model.results.map(\.title), ["rename-break"])
        XCTAssertTrue(index.queries.isEmpty, "the index must not be hit on the keystroke")
    }

    func testTranscriptResultsArriveAfterTheDebounce() async throws {
        index.hits = [TranscriptHit(
            conversationID: "c1", projectPath: "/w/fd", conversationName: "mobile-ui",
            snippet: "don't fire a \u{2}rename\u{3}", timestamp: Date(timeIntervalSince1970: 1)
        )]

        model.query = "rename"
        XCTAssertEqual(model.results.count, 1)

        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)

        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.results.last?.snippet, "don't fire a \u{2}rename\u{3}")
    }

    /// The debounce exists so a fast typist costs one query, not one per keystroke, against
    /// an index that may be mid-backfill.
    func testRapidTypingIssuesASingleIndexQuery() async throws {
        for text in ["r", "re", "ren", "rena", "renam", "rename"] { model.query = text }

        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)

        XCTAssertEqual(index.queries.count, 1)
        XCTAssertEqual(index.queries.first, #""rename"*"#)
    }

    /// The property the whole tier scheme protects: a late transcript result appends below
    /// the name results, so whatever the user had highlighted stays highlighted.
    func testLateTranscriptResultsDoNotMoveTheSelection() async throws {
        index.hits = [TranscriptHit(
            conversationID: "c1", projectPath: "/w/fd", conversationName: "mobile-ui",
            snippet: "x", timestamp: Date(timeIntervalSince1970: 1)
        )]
        model.query = "nme"                   // fuzzy-matches two of the three names
        model.moveSelection(by: 1)
        let held = model.selectedID

        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)

        XCTAssertEqual(model.selectedID, held)
    }

    func testSelectionResetsToTheTopWhenTheQueryChanges() {
        model.query = "nme"
        model.moveSelection(by: 1)
        model.query = "rename"

        XCTAssertEqual(model.selectedID, model.results.first?.id)
    }

    /// Arrowing past either end holds rather than wrapping: at eight visible rows, wrapping
    /// from the top to the bottom of a 200-result list is disorienting, and the top of the
    /// list is where the best match is.
    func testSelectionClampsAtBothEnds() {
        model.query = ""                      // empty query lists all three sessions

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedID, model.results.first?.id)

        model.moveSelection(by: 99)
        XCTAssertEqual(model.selectedID, model.results.last?.id)
    }

    func testActivatingReturnsTheHighlightedResult() {
        model.query = "rename"
        XCTAssertEqual(model.activateSelection()?.title, "rename-break")
    }

    /// Closing must not leave the previous query's results to flash on the next open.
    func testClosingClearsTheQueryAndResults() {
        model.query = "rename"
        model.close()

        XCTAssertTrue(model.query.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
    }

    /// The property `testClosingClearsTheQueryAndResults` cannot actually exercise: a
    /// transcript snippet from an old query must not survive into a new query's results,
    /// even when that new query still has results (so the list is not simply empty).
    func testChangingTheQueryDropsAPreviousQuerysSnippet() async throws {
        index.hits = [TranscriptHit(
            conversationID: "c1", projectPath: "/w/fd", conversationName: "mobile-ui",
            snippet: "x", timestamp: Date(timeIntervalSince1970: 1)
        )]
        model.query = "rename"
        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)
        XCTAssertEqual(model.results.count, 2, "sanity: the transcript hit arrived")

        index.hits = []
        model.query = "wifi"

        XCTAssertTrue(model.results.allSatisfy { $0.snippet == nil })
    }

    /// An empty query has nothing for FTS5 to match, so it must not reach the index at all.
    func testAnEmptyQueryNeverHitsTheIndex() async throws {
        model.query = ""
        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)

        XCTAssertTrue(index.queries.isEmpty)
        XCTAssertEqual(model.results.count, 3)
    }

    /// `moveSelection` against a query that matches nothing must hold `nil` rather than trap
    /// walking an empty `results` array. "xyz" is not a subsequence of any of the three
    /// fixture names, so it clears the prefix, exact, and fuzzy tiers alike.
    func testMovingSelectionWithNoResultsStaysNil() {
        model.query = "xyz"
        XCTAssertTrue(model.results.isEmpty, "sanity: the query really matches nothing")

        model.moveSelection(by: 1)
        XCTAssertNil(model.selectedID)

        model.moveSelection(by: -1)
        XCTAssertNil(model.selectedID)
    }
}
