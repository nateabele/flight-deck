import FleetKit
import XCTest
@testable import FlightDeckMobile

/// `SessionSearchResults`' two pure decisions — what the empty screen says, and where the
/// highlight goes — pulled apart from the view itself so they can be checked as plain values,
/// the way `emptyNotice(for:)`'s own doc comment says it exists to allow.
@MainActor
final class SessionSearchResultsTests: XCTestCase {
    // MARK: The empty screen's notice

    /// **The rule this whole enum exists to enforce.** A disconnected phone must never render
    /// "No results" — a claim about a corpus it is in no position to make — and `.offline` is
    /// exactly the footer a disconnected search sets. This is the one assertion that would fail
    /// if that guarantee were ever quietly dropped.
    func testAnOfflineFooterNeverProducesNoResults() {
        let notice = SessionSearchResults.emptyNotice(for: .offline("Nate's Mac"))

        XCTAssertEqual(notice, .offline("Nate's Mac"))
        XCTAssertNotEqual(notice, .noResults)
    }

    /// The same guarantee during the one-time backfill: a search still running must not read as
    /// "nothing exists" either.
    func testAnIndexingFooterNeverProducesNoResults() {
        let notice = SessionSearchResults.emptyNotice(for: .indexing(done: 1, total: 5))

        XCTAssertEqual(notice, .indexing(done: 1, total: 5))
        XCTAssertNotEqual(notice, .noResults)
    }

    /// No footer at all — the debounce still running, or a query nothing has matched locally
    /// yet — is silence, not a claim. `.waiting` is what keeps the screen blank rather than
    /// flashing "No results" for the ninety milliseconds before the Mac's reply can even land.
    func testNoFooterAtAllWaitsRatherThanClaimingNoResults() {
        XCTAssertEqual(SessionSearchResults.emptyNotice(for: nil), .waiting)
    }

    /// The one footer that legitimately means it: the Mac (or the local ranker, with nothing to
    /// wait on) genuinely answered and found nothing.
    func testOnlyTheEmptyFooterProducesNoResults() {
        XCTAssertEqual(SessionSearchResults.emptyNotice(for: .empty), .noResults)
    }

    // MARK: Highlighting

    /// The matched span is underlined, and only the matched span — the rest of the title
    /// carries no styling at all. Read back through `runs`, the shape a caller cannot get
    /// wrong the way hand-converted `AttributedString.Index`es can.
    func testHighlightedUnderlinesOnlyTheMatchedRange() {
        let text = "rename fix"
        let range = text.startIndex..<text.index(text.startIndex, offsetBy: 6)

        let attributed = SessionSearchResults.highlighted(text, ranges: [range])
        let runs = attributed.runs.map { run in
            (String(attributed[run.range].characters), run.underlineStyle)
        }

        XCTAssertEqual(runs.count, 2, "the matched span and the plain tail: \(runs)")
        XCTAssertEqual(runs[0].0, "rename")
        XCTAssertEqual(runs[0].1, .single)
        XCTAssertEqual(runs[1].0, " fix")
        XCTAssertNil(runs[1].1, "only the matched span is underlined, not the rest")
    }

    /// No ranges at all — a transcript hit's title, whose evidence lives in the snippet instead
    /// — leaves the whole string unstyled rather than underlining something arbitrary.
    func testNoRangesLeavesTheWholeTitleUnstyled() {
        let attributed = SessionSearchResults.highlighted("plain title", ranges: [])

        XCTAssertNil(attributed.underlineStyle)
        XCTAssertEqual(String(attributed.characters), "plain title")
    }

    // MARK: A session result's live status (spec §10)

    /// **The regression this exists for.** A `.session` result used to be drawn from
    /// `SearchResult`'s own fields alone — `nameRow`'s `chevron.right` row, which has no
    /// `waitingFor` because neither `SearchResult` nor the `NameCandidate` it is ranked from
    /// carries one. This asserts the row's session comes from the LIVE fleet, where a
    /// `waiting` session's `waitingFor` is visible — a fix that resolved the id against a
    /// stale copy captured at ranking time, rather than `projects` as passed to this call,
    /// would fail this the moment the fixture's `waitingFor` changed between the two.
    func testALiveSessionIsFoundByIdSoItsWaitingStateStaysCurrent() {
        let id = UUID()
        let projects = [WireProject(
            id: UUID(), name: "flight-deck", path: "/proj",
            sessions: [
                WireSession(
                    id: id, title: "rename fix", agent: "claude",
                    activity: "waiting", waitingFor: "Run the tests?"
                )
            ]
        )]

        let session = SessionSearchResults.liveSession(id: id, in: projects)

        XCTAssertEqual(session?.waitingFor, "Run the tests?",
                        "a session found by search must show it is waiting, the one signal " +
                        "the fleet list exists to convey")
    }

    /// A session closed between the reply landing and this row drawing resolves to `nil`
    /// rather than trapping — the shape `sessionRow`'s fallback branch exists to draw
    /// something for.
    func testALiveSessionLookupIsNilWhenTheSessionHasClosed() {
        let projects = [WireProject(
            id: UUID(), name: "flight-deck", path: "/proj",
            sessions: [WireSession(id: UUID(), title: "unrelated", agent: "claude")]
        )]

        let session = SessionSearchResults.liveSession(id: UUID(), in: projects)

        XCTAssertNil(session)
    }
}
