import FleetKit
import XCTest

final class CLISessionResolverTests: XCTestCase {
    /// `session2` and `session3` share both a UUID prefix (`BBBB`) and a title (`dup`), so each
    /// ambiguity trigger — a shared prefix, a shared title — has a fixture to fire on.
    /// `session1`'s prefix (`AAAA`) and title (`alpha`) are unique to it.
    private let session1 = UUID(uuidString: "AAAA1111-0000-0000-0000-000000000001")!
    private let session2 = UUID(uuidString: "BBBB2222-0000-0000-0000-000000000002")!
    private let session3 = UUID(uuidString: "BBBB3333-0000-0000-0000-000000000003")!
    private let projectA = UUID(uuidString: "CCCCCCCC-0000-0000-0000-0000000000AA")!
    private let projectB = UUID(uuidString: "DDDDDDDD-0000-0000-0000-0000000000BB")!

    private func makeFleet() -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(
                id: projectA, name: "a", path: "/w/a",
                sessions: [
                    WireSession(id: session1, title: "alpha", agent: "claude"),
                ]
            ),
            // `/w/a/nested` is a child of `/w/a` on purpose: it's what makes "longest
            // ancestor wins" a real assertion rather than a coincidence of there being
            // only one candidate.
            WireProject(
                id: projectB, name: "nested", path: "/w/a/nested",
                sessions: [
                    WireSession(id: session2, title: "dup", agent: "claude"),
                    WireSession(id: session3, title: "dup", agent: "claude"),
                ]
            ),
        ])
    }

    // MARK: - self

    func testSelfResolvesToSelfID() {
        XCTAssertEqual(CLISessionResolver.session("self", in: makeFleet(), selfID: session2), .success(session2))
    }

    func testSelfWithoutSelfIDIsNoSelf() {
        XCTAssertEqual(CLISessionResolver.session("self", in: makeFleet(), selfID: nil), .failure(.noSelf))
    }

    // MARK: - UUID and prefix

    func testFullUUIDMatches() {
        let token = session1.uuidString
        XCTAssertEqual(CLISessionResolver.session(token, in: makeFleet(), selfID: nil), .success(session1))
    }

    func testUniqueFourCharacterPrefixMatches() {
        // Lower-cased on purpose: prefix matching is case-insensitive, and `session1`'s
        // stored id is upper-cased (Foundation's own `UUID.uuidString` spelling).
        XCTAssertEqual(CLISessionResolver.session("aaaa", in: makeFleet(), selfID: nil), .success(session1))
    }

    func testThreeCharacterPrefixIsRefusedAsNotFound() {
        // Below the 4-character floor: this must NOT fall through to a prefix search, and
        // "aaa" is not any session's exact title either, so the only honest answer is
        // "no such session" — not an ambiguous match against every `a...` id.
        XCTAssertEqual(CLISessionResolver.session("aaa", in: makeFleet(), selfID: nil), .failure(.notFound("aaa")))
    }

    func testSharedPrefixIsAmbiguous() {
        let result = CLISessionResolver.session("bbbb", in: makeFleet(), selfID: nil)
        guard case .failure(.ambiguous("bbbb", let ids)) = result else {
            return XCTFail("expected .ambiguous, got \(result)")
        }
        XCTAssertEqual(Set(ids), Set([session2, session3]))
    }

    // MARK: - title

    func testUniqueTitleMatches() {
        XCTAssertEqual(CLISessionResolver.session("alpha", in: makeFleet(), selfID: nil), .success(session1))
    }

    func testDuplicateTitleIsAmbiguousListingBothIDs() {
        let result = CLISessionResolver.session("dup", in: makeFleet(), selfID: nil)
        guard case .failure(.ambiguous("dup", let ids)) = result else {
            return XCTFail("expected .ambiguous, got \(result)")
        }
        XCTAssertEqual(Set(ids), Set([session2, session3]))
    }

    // MARK: - project

    func testProjectDotOrHerePicksTheLongestAncestor() {
        // `/w/a` and `/w/a/nested` are both ancestors of the cwd; the nested one is the
        // one whose path is actually current, so it must win, not whichever the fleet
        // happens to list first.
        XCTAssertEqual(CLISessionResolver.project(".", in: makeFleet(), cwd: "/w/a/nested/src"), .success(projectB))
        XCTAssertEqual(CLISessionResolver.project("here", in: makeFleet(), cwd: "/w/a/nested/src"), .success(projectB))
    }

    func testProjectByExactName() {
        XCTAssertEqual(CLISessionResolver.project("a", in: makeFleet(), cwd: "/irrelevant"), .success(projectA))
        XCTAssertEqual(CLISessionResolver.project("nested", in: makeFleet(), cwd: "/irrelevant"), .success(projectB))
    }

    func testProjectNotFound() {
        XCTAssertEqual(
            CLISessionResolver.project("missing", in: makeFleet(), cwd: "/irrelevant"),
            .failure(.notFound("missing"))
        )
    }
    /// A tab titled `cafe` must never resolve to a different tab whose id happens to start
    /// with `CAFE` — the title is what the user typed, the prefix is a coincidence.
    func testAnExactTitleBeatsAUUIDPrefix() {
        let prefixed = UUID(uuidString: "CAFE0000-0000-0000-0000-000000000001")!
        let titled = UUID(uuidString: "EEEE0000-0000-0000-0000-000000000002")!
        let fleet = FleetSnapshot(projects: [
            WireProject(id: projectA, name: "a", path: "/w/a", sessions: [
                WireSession(id: prefixed, title: "other", agent: "claude"),
                WireSession(id: titled, title: "cafe", agent: "claude"),
            ]),
        ])
        XCTAssertEqual(CLISessionResolver.session("cafe", in: fleet, selfID: nil), .success(titled))
        XCTAssertEqual(CLISessionResolver.session("CAFE0", in: fleet, selfID: nil), .success(prefixed),
                       "a prefix nothing is titled still resolves by prefix")
    }
}
