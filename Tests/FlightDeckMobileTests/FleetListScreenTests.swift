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

}
