import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Whether tapping a row in the fleet list actually opens that session.
///
/// This is the one thing about this screen that asserting its pure decisions cannot reach,
/// and it is exactly where its failures have happened: "tapping sessions does nothing" has
/// come back from testing three times now, each time for a different reason, and every time
/// the suite stayed green because every assertion in it was about a value rather than about
/// the row a finger lands on.
///
/// **What a test in this target can and cannot see.** It can render the screen for real and
/// drive a `List` the way UIKit ends up driving it — a row's tap arrives as a collection-view
/// selection — so everything from the selection inwards is covered. What it cannot do is
/// deliver the touch, because synthesizing one needs a UI-testing host and this is a
/// unit-test bundle. That gap is precisely where the last bug lived: the touch was recognised
/// and never reached the selection. So the first test below asserts the *shape* that caused
/// it instead, which is the only view of it available from here.
@MainActor
final class FleetListScreenTests: XCTestCase {
    private var server: FleetSocketServer!
    private var window: UIWindow!

    override func tearDown() async throws {
        server?.stop()
        server = nil
        window = nil
        try await super.tearDown()
    }

    /// **The regression this file exists for.**
    ///
    /// The row used to send `markRead` from a `.simultaneousGesture(TapGesture())` hung off
    /// its `NavigationLink`, on the theory that a gesture *beside* a link avoids the two
    /// competing recognisers a `Button` *around* one would create. It creates the same two,
    /// and the extra one wins often enough to swallow the tap: on a real phone the first row
    /// tapped opened, and from the moment the reader came back from it no row in the list
    /// would open again — UIKit logged every one of those taps and no push ever followed.
    ///
    /// Asserted through the view's own type, because that is where a gesture modifier is
    /// visible from a unit test: SwiftUI spells the whole hierarchy into it, so a
    /// `.gesture`/`.simultaneousGesture`/`.highPriorityGesture` anywhere on this screen
    /// appears as an `AddGestureModifier` in `body`'s type and nothing else does. A coarse
    /// instrument, pointed at exactly one thing: this screen is a list of links, and a link
    /// is the only thing on it that may handle a tap.
    func testNoGestureIsHungOffTheLinksThatOpenSessions() async throws {
        let model = try await connectedModel()
        let hierarchy = String(describing: type(of: FleetListScreen(model: model).body))

        XCTAssertFalse(
            hierarchy.contains("GestureModifier"),
            "a gesture beside the row's link competes with it for the tap that opens the "
                + "session, and wins often enough that rows stop opening: \(hierarchy)"
        )
    }

    /// The other half, and the user-visible one: every row opens, and coming back from one
    /// does not cost the rest of the list its destination.
    ///
    /// Stated as a sequence rather than as two independent rows on purpose — the reported
    /// failure was never "this row is broken", it was "nothing opens once you have been into
    /// one", which a test that opens a single row cannot see.
    func testEveryRowOpensItsSessionIncludingAfterComingBackFromAnother() async throws {
        let model = try await connectedModel()
        let (collection, navigation) = try render(FleetListScreen(model: model))

        for row in 0..<2 {
            select(row: row, in: collection)
            XCTAssertEqual(
                navigation.viewControllers.count, 2,
                "row \(row) did not open its conversation"
            )
            navigation.popViewController(animated: false)
            settle()
        }
    }

    // MARK: Driving the list

    /// A tap, as far as a `List` is concerned: UIKit's own recogniser ends in exactly this
    /// call, and `NavigationLink`'s push hangs off it.
    private func select(row: Int, in collection: UICollectionView) {
        let path = IndexPath(item: row, section: collection.numberOfSections - 1)
        collection.delegate?.collectionView?(collection, didSelectItemAt: path)
        settle()
    }

    // MARK: Rendering

    /// Hosts `view` in a real window and hands back the two things a row's tap runs through.
    ///
    /// A window rather than a detached `UIHostingController`: a `List` builds no cells at all
    /// until it is in one, so a detached controller answers "no rows" for a working screen
    /// and a broken one alike.
    private func render(
        _ view: some View
    ) throws -> (UICollectionView, UINavigationController) {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        settle()

        let collection = descendants(of: host.view)
            .compactMap { $0 as? UICollectionView }.first
        let navigation = host.children.compactMap { $0 as? UINavigationController }.first
        return try (
            XCTUnwrap(collection, "the fleet list did not render a list"),
            XCTUnwrap(navigation, "the fleet list did not render a navigation stack")
        )
    }

    /// A turn of the run loop. SwiftUI fills cells and pushes destinations from a later pass
    /// than the one `layoutIfNeeded` forces, so asserting straight after an action reads the
    /// state before it.
    private func settle() {
        window?.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window?.layoutIfNeeded()
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    // MARK: The fixture

    /// A `FleetModel` holding the fixture fleet, filled from a real socket.
    ///
    /// A real server rather than a seam on `FleetModel`: `fleet` is `private(set)` and filled
    /// only by a connector, and adding a setter so a test could skip the socket would be a
    /// seam the app could drift into using for anything else. `FleetSocketServer` is in
    /// `FleetKit`, builds for iOS, and listens on the simulator's own loopback.
    private func connectedModel() async throws -> FleetModel {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        self.server = server
        server.onHello = { _, _ in [.snapshot(seq: 0, fleet: Self.fleet, reason: .initial)] }
        server.onCommand = { _, cid, _ in .ack(cid: cid) }
        // Answered rather than left hanging: the screen a selection pushes asks for a page as
        // it opens, and an unanswered request leaves a fetch in flight for fifteen seconds —
        // which outlives the test and lands its deadline in the next one.
        server.onRequest = { _, cid, request, reply in
            guard case .timeline(let session, _, _) = request else { return }
            reply(.page(cid: cid, TimelinePage(
                session: session, items: [], start: 0, end: 0, hasMore: false, reset: false
            )))
        }
        let port = try await server.start(keys: [key], port: nil)

        let store = InMemoryPairedMacStore()
        store.save(PairedMac(
            key: key, macName: "Studio", serviceName: "studio-tests._flightdeck._tcp",
            endpoints: ["127.0.0.1:\(port.rawValue)"]
        ))
        let model = FleetModel(store: store)

        let deadline = Date().addingTimeInterval(10)
        while model.fleet.projects.flatMap(\.sessions).count < 2, Date() < deadline {
            // A sleep rather than a run-loop spin: this is an async context, and yielding the
            // main actor is what lets the connector's own main-queue callbacks land at all.
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            model.fleet.projects.flatMap(\.sessions).count, 2,
            "the fixture fleet never arrived"
        )
        return model
    }

    /// **Two rows that differ in nothing a view can branch on**, which is what the deck this
    /// was reported against looked like: same agent, no status either side, both read. A
    /// fixture where one row is busy and the other idle, or one unread and the other read,
    /// would let a fix that only works for one of those shapes pass — and the report was that
    /// two *identical* rows behaved differently.
    private static let fleet = FleetSnapshot(projects: [
        WireProject(
            id: UUID(), name: "nate", path: "/Users/nate",
            sessions: [
                WireSession(id: UUID(), title: "Home", agent: "claude"),
                WireSession(id: UUID(), title: "session 2", agent: "claude"),
            ]
        )
    ])
    // MARK: The New Session menu

    private func option(
        _ agent: String, _ name: String, index: Int, account: String?, isDefault: Bool = false
    ) -> WireNewSessionOption {
        WireNewSessionOption(
            agent: agent, agentName: name, index: index,
            accountName: account, isDefault: isDefault
        )
    }

    /// **The order is the Mac's ⌘N ladder, so it is kept rather than sorted** — and asserted
    /// rather than trusted, because a sort anywhere in this translation would put the phone
    /// quietly out of step with the sidebar about what ⌘N does, with nothing else to notice.
    /// The names below are deliberately in the wrong alphabetical order for the arrival order.
    func testAgentGroupsKeepTheOrderTheyArrivedIn() {
        let groups = FleetListScreen.agentGroups(in: [
            option("codex", "Codex", index: 0, account: nil),
            option("claude", "Claude", index: 0, account: "Work", isDefault: true),
            option("claude", "Claude", index: 1, account: "Personal"),
        ])
        XCTAssertEqual(groups.map(\.agent), ["codex", "claude"],
                       "arrival order, not alphabetical")
        XCTAssertEqual(groups[1].rows.map(\.index), [0, 1])
        XCTAssertEqual(groups[1].name, "Claude")
    }

    /// An agent's rows stay together even when the Mac interleaves them, so a submenu is never
    /// split into two menus of one.
    func testAnAgentsRowsAreGroupedTogether() {
        let groups = FleetListScreen.agentGroups(in: [
            option("claude", "Claude", index: 0, account: "Work"),
            option("codex", "Codex", index: 0, account: nil),
            option("claude", "Claude", index: 1, account: "Personal"),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].rows.count, 2, "both claude rows, in one group")
    }

    func testNoOptionsIsNoGroups() {
        XCTAssertTrue(FleetListScreen.agentGroups(in: []).isEmpty)
    }

    // MARK: A search result's tap destination

    private func result(
        _ kind: SearchResultKind, title: String = "session", projectPath: String = "/proj"
    ) -> SearchResult {
        SearchResult(
            id: title, kind: kind, title: title, projectName: "proj", projectPath: projectPath,
            tier: .exact, recency: Date(timeIntervalSince1970: 1), highlightedRanges: [],
            snippet: nil, conversationID: nil
        )
    }

    /// A `.session` result already names its open tab, so the destination is the id it carries
    /// — no lookup at all, and unaffected by whatever the fleet happens to hold.
    func testASessionResultsDestinationIsTheIdItAlreadyCarries() {
        let id = UUID()
        let destination = FleetListScreen.localDestination(for: result(.session(id)), in: [])

        XCTAssertEqual(destination, id)
    }

    /// **The regression this exists for.** A `.project` result's `conversationID` is always
    /// `nil` — see `PhoneSearchCandidates.build` — so it cannot be opened through the Mac the
    /// way a transcript hit is; the brief said it should be, and the Mac's own
    /// `FleetService.openConversation` would refuse it every time. Activating it must resolve
    /// locally to the project's first session instead, per `SearchResultKind.project`'s own doc
    /// comment.
    func testAProjectResultsDestinationIsTheProjectsFirstSession() {
        let first = UUID()
        let projects = [
            WireProject(id: UUID(), name: "nate", path: "/proj", sessions: [
                WireSession(id: first, title: "one", agent: "claude"),
                WireSession(id: UUID(), title: "two", agent: "claude"),
            ])
        ]

        let destination = FleetListScreen.localDestination(
            for: result(.project, projectPath: "/proj"), in: projects
        )

        XCTAssertEqual(destination, first, "the FIRST session, not any session in the project")
    }

    /// A project result naming a project the fleet no longer holds — closed while the search
    /// was open — resolves to nothing to push, rather than crashing on a force unwrap.
    func testAProjectResultsDestinationIsNilWhenTheProjectIsNoLongerInTheFleet() {
        let destination = FleetListScreen.localDestination(
            for: result(.project, projectPath: "/gone"), in: []
        )

        XCTAssertNil(destination)
    }

    /// `.conversation` is never resolved locally — it may name a conversation with no tab of
    /// its own at all, which only the Mac can open. A `nil` here is what sends
    /// `handleSearchTap` down the `requestOpenConversation` path instead of pushing directly.
    func testAConversationResultsDestinationIsNeverResolvedLocally() {
        let projects = [
            WireProject(id: UUID(), name: "nate", path: "/proj", sessions: [
                WireSession(id: UUID(), title: "one", agent: "claude"),
            ])
        ]

        let destination = FleetListScreen.localDestination(
            for: result(.conversation("abc"), projectPath: "/proj"), in: projects
        )

        XCTAssertNil(destination, "a conversation hit always needs the Mac's round trip")
    }

    // MARK: What the candidate wiring actually composes

    /// A session the fleet is showing right now must be a candidate the ranker can match —
    /// the one thing the `.onChange(of: model.fleet)` trigger exists to keep current. If the
    /// wiring passed the wrong projects, or nothing at all, this session would never rank.
    func testASessionInTheFleetIsAmongTheComposedCandidates() {
        let projects = [WireProject(
            id: UUID(), name: "flight-deck", path: "/proj",
            sessions: [WireSession(id: UUID(), title: "rename fix", agent: "claude")]
        )]

        let candidates = FleetListScreen.searchCandidates(projects: projects, catalogue: nil)

        XCTAssertTrue(candidates.contains { $0.name == "rename fix" })
    }

    /// No catalogue reply yet — the Mac hasn't answered, or the phone only just connected —
    /// must not crash and must not invent a conversation candidate out of nothing. This is the
    /// nil-coalescing this function does in place of a `WireConversationCatalogue.empty` that
    /// doesn't exist; if it were removed, a nil catalogue would trap instead of composing.
    func testANilCatalogueComposesOnlyFromTheFleet() {
        let projects = [WireProject(
            id: UUID(), name: "flight-deck", path: "/proj",
            sessions: [WireSession(id: UUID(), title: "only session", agent: "claude")]
        )]

        let candidates = FleetListScreen.searchCandidates(projects: projects, catalogue: nil)

        XCTAssertEqual(candidates.map(\.name), ["only session", "flight-deck"])
    }

    /// The catalogue arriving AFTER the fleet — the ordinary case, since the Mac answers the
    /// fleet snapshot before the search backfill — contributes its own conversations once it
    /// does. This is the `.onChange(of: model.conversationCatalogue)` trigger's whole reason to
    /// exist: without a second call to this function on that reply, an unclaimed past
    /// conversation would stay unfindable until the screen was torn down and rebuilt.
    func testACatalogueArrivingAfterTheFleetContributesItsConversations() {
        let projects = [WireProject(id: UUID(), name: "flight-deck", path: "/proj")]
        let withoutCatalogue = FleetListScreen.searchCandidates(projects: projects, catalogue: nil)
        XCTAssertFalse(withoutCatalogue.contains { $0.name == "old chat" })

        let catalogue = WireConversationCatalogue(
            conversations: [WireConversation(id: "abc123", name: "old chat", projectPath: "/proj")],
            sessionActivity: [:]
        )
        let withCatalogue = FleetListScreen.searchCandidates(projects: projects, catalogue: catalogue)

        XCTAssertTrue(withCatalogue.contains { $0.name == "old chat" })
    }

    // MARK: A search tap's failure is surfaced, not silent

    /// **The regression this exists for.** `handleSearchTap`'s completion used to be
    /// `guard case .success(let id) = outcome else { return }`, which folded
    /// `unknown_conversation`, `launch_failed` AND `.disconnected` into the same silent
    /// nothing — a tap that did nothing at all, with no way to tell a dropped socket from a
    /// dangling account. This asserts the three named outcomes produce three DIFFERENT
    /// messages, which a mapping collapsed back to `return`, or back to one shared string,
    /// could not do.
    func testEachSearchTapFailureProducesItsOwnMessage() {
        let disconnected = FleetListScreen.searchOpenFailureMessage(
            for: .disconnected, macName: "Nate's Mac"
        )
        let unknown = FleetListScreen.searchOpenFailureMessage(
            for: .server(code: "unknown_conversation"), macName: "Nate's Mac"
        )
        let launchFailed = FleetListScreen.searchOpenFailureMessage(
            for: .server(code: "launch_failed"), macName: "Nate's Mac"
        )

        XCTAssertNotEqual(disconnected, unknown)
        XCTAssertNotEqual(disconnected, launchFailed)
        XCTAssertNotEqual(unknown, launchFailed)
        XCTAssertTrue(disconnected.contains("Nate's Mac"), "names the Mac, per this file's style")
        XCTAssertTrue(unknown.contains("Nate's Mac"))
        XCTAssertTrue(launchFailed.contains("Nate's Mac"))
    }

    /// An old Mac's code this build has never heard of — or a future one's — falls to a
    /// generic message rather than staying silent. `FleetRequestError.server`'s own doc
    /// comment requires exactly this of every client on the channel.
    func testAnUnrecognisedServerCodeFallsToAGenericMessageRatherThanSilence() {
        let message = FleetListScreen.searchOpenFailureMessage(
            for: .server(code: "some_future_code"), macName: "Nate's Mac"
        )

        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.contains("Nate's Mac"))
    }
}
