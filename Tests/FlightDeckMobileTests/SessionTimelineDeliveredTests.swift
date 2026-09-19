import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A stand-in that answers both verbs on demand. Modelled on `SessionTimelinePromptTests`'
/// `StubFleet` — each file rolls its own because the protocol conformance is trivial and a
/// shared one would be a dependency across files that otherwise know nothing of each other.
@MainActor
private final class StubFleet: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
    private(set) var viewingReports: [UUID?] = []
    func viewing(_ session: UUID?) { viewingReports.append(session) }

    private(set) var requests: [FleetRequest] = []
    private(set) var commands: [FleetCommand] = []
    private var pendingPages: [(Result<TimelinePage, FleetRequestError>) -> Void] = []
    private var pendingAcks: [(Result<Void, FleetRequestError>) -> Void] = []

    var promptTokens: [UUID] {
        commands.compactMap { if case .prompt(_, let t, _) = $0 { return t } else { return nil } }
    }

    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {
        requests.append(request)
        pendingPages.append(completion)
    }

    func markRead(_ id: UUID) {}

    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        commands.append(command)
        pendingAcks.append(completion)
    }

    var sent: FleetCommand?

    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        sent = command
    }

    func answerCommand(_ result: Result<Void, FleetRequestError>, line: UInt = #line) {
        guard !pendingAcks.isEmpty else {
            return XCTFail("no command was sent", line: line)
        }
        pendingAcks.removeFirst()(result)
    }

    func answerPage(_ result: Result<TimelinePage, FleetRequestError>, line: UInt = #line) {
        guard !pendingPages.isEmpty else {
            return XCTFail("no page was requested", line: line)
        }
        pendingPages.removeFirst()(result)
    }

    /// Spins the main actor until a page request is outstanding, then answers it. The same
    /// device as `SessionTimelineBlockedTests.StubPager.answerWhenAsked` — a background chase
    /// sleeps between attempts, so a test driving it cannot know exactly when the next request
    /// will exist.
    func answerWhenAsked(
        _ result: Result<TimelinePage, FleetRequestError>, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while pendingPages.isEmpty {
            guard ContinuousClock.now < deadline else {
                return XCTFail("no page was ever asked for", line: line)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        pendingPages.removeFirst()(result)
    }
}

/// `SessionTimelineModel.promptTyped(_:)` — the phone's side of `FleetEvent.promptTyped`,
/// which reports the exact moment the Mac typed a queued prompt into the agent. See
/// `PromptOutbox.deliver`.
@MainActor
final class SessionTimelineDeliveredTests: XCTestCase {
    private let session = UUID()

    private func model(_ fleet: StubFleet) -> SessionTimelineModel {
        SessionTimelineModel(sessionID: session, fleet: fleet)
    }

    /// `.accepted` is the state a `promptTyped` event always arrives on top of: the Mac has
    /// already acked, and this is the report that it went further and actually typed the
    /// thing in.
    func testPromptTypedMovesAnAcceptedEntryToDelivered() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.success(()))
        let token = try! XCTUnwrap(fleet.promptTokens.first)

        model.promptTyped(token)

        XCTAssertEqual(model.outbox.entries.map(\.state), [.delivered])
    }

    /// `promptTyped` arrives off the socket, entirely outside `fetch`'s success path — the
    /// only other place `rebuild()` runs. Without its own call, a just-delivered ghost would
    /// sit in `outbox.entries` unseen in `model.rendered` until an unrelated fetch happened to
    /// land, which is the regression `rebuild()`'s doc comment claims cannot happen.
    func testPromptTypedMakesTheGhostAppearInRenderedWithoutAnotherFetch() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.open()
        fleet.answerPage(.success(TimelinePage(
            session: session, items: [], start: 0, end: 0, hasMore: false, reset: false
        )))
        model.send("ship it")
        fleet.answerCommand(.success(()))
        let token = try! XCTUnwrap(fleet.promptTokens.first)
        let renderedBefore = model.rendered
        let rebuildsBefore = model.rebuildCount

        model.promptTyped(token)

        XCTAssertEqual(model.rebuildCount, rebuildsBefore + 1,
                       "the delivery itself must recompute rendered exactly once")
        XCTAssertEqual(model.rendered.count, renderedBefore.count + 1,
                       "the delivered entry becomes a ghost row in rendered")
        XCTAssertTrue(model.rendered.last?.isGhost ?? false,
                      "the new row is the ghost, not a real transcript item")
    }

    /// A "nothing new" page for the given session — the ordinary shape of a poll that lands
    /// while the ghost is still waiting on its own turn.
    private func emptyPage() -> TimelinePage {
        TimelinePage(session: session, items: [], start: 0, end: 0, hasMore: false, reset: false)
    }

    /// The direct regression test for the reported bug: a delivered ghost must retire on its
    /// own, from `chaseDelivery`'s background retries, with no screen-scoped trigger firing at
    /// all — nothing here ever calls `updateStatus`, `linkResumed`, or re-opens the screen.
    func testChaseDeliveryRetiresGhostWithNoOtherTrigger() async throws {
        let fleet = StubFleet()
        let model = model(fleet)
        model.deliveryChaseRetries = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
        model.send("ship it")
        fleet.answerCommand(.success(()))
        let token = try XCTUnwrap(fleet.promptTokens.first)

        model.promptTyped(token)
        XCTAssertEqual(model.outbox.entries.map(\.state), [.delivered])

        // The fetch `send`'s own success handler kicked off, then two of the chase's own
        // retries, all landing with nothing new yet.
        await fleet.answerWhenAsked(.success(emptyPage()))
        await fleet.answerWhenAsked(.success(emptyPage()))
        // Finally, the matching turn shows up in the transcript.
        await fleet.answerWhenAsked(.success(.init(
            session: session,
            items: [TimelineItem(
                id: "10#0", kind: .userTurn, status: .complete, body: .init(text: "ship it")
            )],
            start: 0, end: 10, hasMore: false, reset: false
        )))

        let deadline = ContinuousClock.now + .seconds(5)
        while !model.outbox.entries.isEmpty {
            guard ContinuousClock.now < deadline else {
                return XCTFail("the chase never retired the ghost")
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// No orphaned `Task` keeps calling `loadNewer()` once a chased entry is dismissed — proven
    /// by the fleet's request count plateauing rather than continuing to grow across several
    /// more of the schedule's rounds.
    func testChaseStopsOnceDismissed() async throws {
        let fleet = StubFleet()
        let model = model(fleet)
        model.deliveryChaseRetries = Array(repeating: .milliseconds(30), count: 6)
        model.send("ship it")
        fleet.answerCommand(.success(()))
        let token = try XCTUnwrap(fleet.promptTokens.first)

        model.promptTyped(token)
        // The send's own post-ack fetch, then one round of the chase's own retries — both
        // landing with nothing new.
        await fleet.answerWhenAsked(.success(emptyPage()))
        await fleet.answerWhenAsked(.success(emptyPage()))

        let countAtDismiss = fleet.requests.count
        model.dismiss(token)

        // Give the chase several more scheduled rounds' worth of real time to prove it does
        // not ask again.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fleet.requests.count, countAtDismiss,
                       "a dismissed ghost's chase must not keep polling")
        XCTAssertTrue(model.outbox.entries.isEmpty)
    }

    /// Two prompts delivered concurrently retire independently: the first's matching turn
    /// landing must not stop, block, or otherwise interfere with the second's own chase.
    func testConcurrentDeliveriesRetireIndependently() async throws {
        let fleet = StubFleet()
        let model = model(fleet)
        model.deliveryChaseRetries = Array(repeating: .milliseconds(1), count: 6)

        model.send("first")
        fleet.answerCommand(.success(()))
        let tokenA = try XCTUnwrap(fleet.promptTokens.first)
        await fleet.answerWhenAsked(.success(emptyPage())) // first's own post-ack fetch

        model.send("second")
        fleet.answerCommand(.success(()))
        let tokenB = try XCTUnwrap(fleet.promptTokens.last)
        await fleet.answerWhenAsked(.success(emptyPage())) // second's own post-ack fetch

        model.promptTyped(tokenA)
        model.promptTyped(tokenB)
        XCTAssertEqual(Set(model.outbox.entries.map(\.id)), [tokenA, tokenB])

        // Only "first"'s turn shows up — tokenA retires, tokenB's chase must keep going alone.
        await fleet.answerWhenAsked(.success(.init(
            session: session,
            items: [TimelineItem(
                id: "10#0", kind: .userTurn, status: .complete, body: .init(text: "first")
            )],
            start: 0, end: 10, hasMore: false, reset: false
        )))

        let deadlineA = ContinuousClock.now + .seconds(5)
        while model.outbox.entries.contains(where: { $0.id == tokenA }) {
            guard ContinuousClock.now < deadlineA else {
                return XCTFail("tokenA's chase never retired it")
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.outbox.entries.map(\.id), [tokenB],
                       "only the matched entry retires; the other keeps chasing on its own")

        // "second"'s turn shows up later — tokenB retires too, from its own chase.
        await fleet.answerWhenAsked(.success(.init(
            session: session,
            items: [TimelineItem(
                id: "20#0", kind: .userTurn, status: .complete, body: .init(text: "second")
            )],
            start: 10, end: 20, hasMore: false, reset: false
        )))

        let deadlineB = ContinuousClock.now + .seconds(5)
        while !model.outbox.entries.isEmpty {
            guard ContinuousClock.now < deadlineB else {
                return XCTFail("tokenB's chase never retired it")
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
