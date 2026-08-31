import FleetKit
import XCTest
@testable import FlightDeckMobile

final class PhoneSearchCandidatesTests: XCTestCase {
    /// A conversation with a live tab is contributed by the tab and not again by the
    /// catalogue — otherwise it appears twice with two different meanings for a tap.
    func testALiveSessionClaimsItsConversation() {
        let id = UUID()
        let projects = [WireProject(
            id: UUID(), name: "flight-deck", path: "/proj",
            sessions: [WireSession(id: id, title: "rename fix", agent: "claude")]
        )]
        let catalogue = WireConversationCatalogue(
            conversations: [WireConversation(
                id: id.uuidString.lowercased(), name: "rename fix", projectPath: "/proj"
            )],
            sessionActivity: [:]
        )

        let candidates = PhoneSearchCandidates.build(
            projects: projects, catalogue: catalogue
        )

        XCTAssertEqual(candidates.filter { $0.name == "rename fix" }.count, 1)
    }

    /// A catalogue entry for a project the phone is not showing is dropped: tapping it
    /// would ask the Mac to re-add a project the user removed.
    func testCatalogueEntriesOutsideTheFleetAreDropped() {
        let candidates = PhoneSearchCandidates.build(
            projects: [WireProject(id: UUID(), name: "a", path: "/a")],
            catalogue: WireConversationCatalogue(
                conversations: [WireConversation(id: "x", name: "gone", projectPath: "/b")],
                sessionActivity: [:]
            )
        )
        XCTAssertFalse(candidates.contains { $0.name == "gone" })
    }

    /// No entry in `sessionActivity` sorts last within its tier rather than crashing or
    /// sorting first.
    func testAbsentSessionActivityBecomesDistantPast() {
        let candidates = PhoneSearchCandidates.build(
            projects: [WireProject(
                id: UUID(), name: "a", path: "/a",
                sessions: [WireSession(id: UUID(), title: "t", agent: "claude")]
            )],
            catalogue: WireConversationCatalogue(conversations: [], sessionActivity: [:])
        )
        XCTAssertEqual(candidates.first { $0.name == "t" }?.lastActivity, .distantPast)
    }

    /// A session present in `sessionActivity` carries that transcript's mtime, not
    /// `.distantPast` — this is the whole reason recency rides the catalogue reply rather
    /// than a `WireSession` field.
    func testPresentSessionActivityIsUsedAsIs() {
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates = PhoneSearchCandidates.build(
            projects: [WireProject(
                id: UUID(), name: "a", path: "/a",
                sessions: [WireSession(id: id, title: "t", agent: "claude")]
            )],
            catalogue: WireConversationCatalogue(
                conversations: [], sessionActivity: [id.uuidString: stamp]
            )
        )
        XCTAssertEqual(candidates.first { $0.name == "t" }?.lastActivity, stamp)
    }

    /// The whole reason this function takes a catalogue: an unclaimed conversation for an
    /// open project must actually surface, as a `.conversation` candidate carrying the
    /// conversation id, a project name derived from the path (not the raw path itself), and
    /// `.distantPast` recency. If the append loop were deleted, or its `where` clause
    /// inverted, this conversation would never appear and this assertion would fail.
    func testAnUnclaimedConversationInAnOpenProjectAppearsAsAConversationCandidate() {
        let candidates = PhoneSearchCandidates.build(
            projects: [WireProject(id: UUID(), name: "flight-deck", path: "/proj")],
            catalogue: WireConversationCatalogue(
                conversations: [WireConversation(
                    id: "abc123", name: "old chat", projectPath: "/proj"
                )],
                sessionActivity: [:]
            )
        )

        let candidate = candidates.first { $0.name == "old chat" }
        XCTAssertEqual(candidate?.kind, .conversation("abc123"))
        XCTAssertEqual(candidate?.projectName, "proj")
        XCTAssertEqual(candidate?.lastActivity, .distantPast)
    }

    /// A project row carries its newest session's activity, not its first or its last in
    /// list order — so a project whose fresher session is listed FIRST still sorts as fresh.
    /// The fresher session is deliberately first here: were the implementation to regress
    /// from `max` to "whichever session is processed last wins", this ordering is exactly
    /// what would expose it (a same-order regression would not).
    func testAProjectCandidateCarriesTheNewerOfItsTwoSessionsActivity() {
        let older = UUID()
        let newer = UUID()
        let olderStamp = Date(timeIntervalSince1970: 1_000)
        let newerStamp = Date(timeIntervalSince1970: 2_000)
        let candidates = PhoneSearchCandidates.build(
            projects: [WireProject(
                id: UUID(), name: "flight-deck", path: "/proj",
                sessions: [
                    WireSession(id: newer, title: "new", agent: "claude"),
                    WireSession(id: older, title: "old", agent: "claude"),
                ]
            )],
            catalogue: WireConversationCatalogue(
                conversations: [],
                sessionActivity: [
                    older.uuidString: olderStamp,
                    newer.uuidString: newerStamp,
                ]
            )
        )

        XCTAssertEqual(
            candidates.first { $0.kind == .project }?.lastActivity, newerStamp
        )
    }
}
