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
}
