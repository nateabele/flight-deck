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
            id: a.id, activity: "busy", waitingFor: nil, subagentCount: 3,
            hasBackgroundWork: false, openPromptCall: .noPrompt
        )))
        // `.noPrompt` and never `.unreported`, even for the waiting tab: this store has no
        // fleet behind it, so `openPromptCallReader` names nothing — and "I looked and found
        // nothing" is what the Mac asserts, which is what retires a phone's card. A tab that
        // is blocked on a dialog this build cannot name reaches the wire exactly this way.
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: b.id, activity: "waiting", waitingFor: "input needed", subagentCount: 0,
            hasBackgroundWork: false, openPromptCall: .noPrompt
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
            id: session.id, activity: nil, waitingFor: nil, subagentCount: 0,
            hasBackgroundWork: false, openPromptCall: .noPrompt
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
            id: session.id, activity: "busy", waitingFor: nil, subagentCount: 4,
            hasBackgroundWork: false, openPromptCall: .noPrompt
        )))
    }

    /// `commitStatuses`'s guard lets a background-only tick through — Task 2 widened it to
    /// `next != statuses || backgroundWork != backgroundWorkSessions` on purpose, so a task
    /// starting or ending under an otherwise-idle tab is not swallowed. `emitActivity` has to
    /// meet that halfway: a tick where `activity` never moves must still be announced when
    /// only the background flag did, or the widened guard buys nothing for a connected phone.
    func testABackgroundWorkOnlyChangeIsAnnounced() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.applyRegistry([1: .init(
            pid: 1, sessionID: session.pinnedConversationID, activity: .idle, waitingFor: nil,
            startedAt: 1, cwd: "/w/alpha", procStart: "a", reportsBackgroundWork: false)])
        let replicator = attachedReplicator(to: store)

        // Same activity, same everything else — only `reportsBackgroundWork` flips.
        store.applyRegistry([1: .init(
            pid: 1, sessionID: session.pinnedConversationID, activity: .idle, waitingFor: nil,
            startedAt: 1, cwd: "/w/alpha", procStart: "a", reportsBackgroundWork: true)])

        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: session.id, activity: "idle", waitingFor: nil, subagentCount: 0,
            hasBackgroundWork: true, openPromptCall: .noPrompt
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

    /// The mutation and its event must not be separable: a phone left un-notified is silently
    /// wrong until it reconnects, and nothing crashes to tell you.
    func testAPIErrorEmitsOnceAndOnlyOnChange() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        func emitted() -> Int {
            replicator.recorded.filter {
                if case .apiErrorChanged = $0 { return true } else { return false }
            }.count
        }

        store.apply(.apiError(SessionAPIError(status: 529, kind: "overloaded")), to: session.id)
        XCTAssertEqual(store.apiErrors[session.id]?.status, 529)
        XCTAssertEqual(emitted(), 1)

        store.apply(.apiError(SessionAPIError(status: 529, kind: "overloaded")), to: session.id)
        XCTAssertEqual(emitted(), 1, "an unchanged error must not re-emit")

        store.apply(.apiError(nil), to: session.id)
        XCTAssertNil(store.apiErrors[session.id])
        XCTAssertEqual(emitted(), 2)
    }
}
