import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class FleetFieldEmissionTests: XCTestCase {
    private func store() -> SessionStore { SessionStore(provider: nil, persistence: nil) }

    /// The distinction a diff cannot carry, and the reason this is an event log: both
    /// produce an identical `title` field and they are different facts.
    func testAUserRenameAndAnAgentRenameAreDistinguishable() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)

        store.rename(session.id, to: "typed")
        XCTAssertTrue(replicator.recorded.contains(
            .renamed(id: session.id, title: "typed", origin: .user)
        ))

        store.applyExternalTitle(session.id, "self-named")
        XCTAssertTrue(replicator.recorded.contains(
            .renamed(id: session.id, title: "self-named", origin: .agent)
        ))
    }

    /// `applyExternalTitle`'s equality check is the loop guard against our own rename echoing
    /// back. An event emitted before that guard would put the echo on the wire.
    func testAnEchoedExternalTitleEmitsNothing() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.rename(session.id, to: "settled")
        let replicator = attachedReplicator(to: store)
        store.applyExternalTitle(session.id, "settled")
        XCTAssertTrue(replicator.recorded.isEmpty)
    }

    func testAStatusTickEmitsOneActivityEventPerChangedSession() {
        let store = store()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        store.applyRegistryForTesting([
            a.id: SessionStatus(activity: .busy, subagentCount: 3),
            b.id: SessionStatus(activity: .waiting, waitingFor: "input needed")
        ])
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: a.id, activity: "busy", waitingFor: nil, subagentCount: 3
        )))
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: b.id, activity: "waiting", waitingFor: "input needed", subagentCount: 0
        )))
    }

    /// A tab whose agent exits goes statusless, which is not the same as idle. Emitting
    /// nothing here would leave the phone showing whatever it was doing when it died.
    func testASessionLosingItsProcessEmitsANilActivity() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        let replicator = attachedReplicator(to: store)
        store.applyRegistryForTesting([:])
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: session.id, activity: nil, waitingFor: nil, subagentCount: 0
        )))
    }

    /// The second, easily-missed writer of `statuses`. This is the site the drift assertion
    /// was built to catch, so it gets a test of its own.
    func testASubagentCountArrivingOnItsOwnIsAnnounced() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        let replicator = attachedReplicator(to: store)
        store.applySubagentCount(session.id, 4)
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: session.id, activity: "busy", waitingFor: nil, subagentCount: 4
        )))
    }

    func testMarkingUnreadAndReadingItAgainAreBothAnnounced() {
        let store = store()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.selectSession(b.id)
        let replicator = attachedReplicator(to: store)

        store.markUnread(a.id)
        XCTAssertTrue(replicator.recorded.contains(.unreadChanged(id: a.id, isUnread: true)))

        // Selecting a tab is what marks it read — the one unread write that happens in a
        // `didSet` rather than in a named method.
        store.selectSession(a.id)
        XCTAssertTrue(replicator.recorded.contains(.unreadChanged(id: a.id, isUnread: false)))
    }

    func testMarkingAnAlreadyUnreadSessionEmitsNothingNew() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.selectSession(session.id)
        store.markUnread(session.id)
        let replicator = attachedReplicator(to: store)
        store.markUnread(session.id)
        XCTAssertTrue(replicator.recorded.isEmpty, "an unchanged flag is not an event")
    }

    /// A session finishing while the user is looking elsewhere is the whole point of the
    /// unread mark, and it is set from `applyReadState` rather than from any named method.
    func testFinishingUnwatchedIsAnnouncedAsUnread() {
        let store = store()
        let watched = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let other = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.selectSession(other.id)
        store.applyRegistryForTesting([watched.id: SessionStatus(activity: .busy)])
        let replicator = attachedReplicator(to: store)
        store.applyRegistryForTesting([watched.id: SessionStatus(activity: .idle)])
        XCTAssertTrue(replicator.recorded.contains(.unreadChanged(id: watched.id, isUnread: true)))
    }
}
