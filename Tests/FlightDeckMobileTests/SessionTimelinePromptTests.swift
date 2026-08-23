import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A stand-in that answers both verbs on demand. The real `FleetModel` needs a pairing, a
/// Bonjour browse and a Mac to answer anything at all, so this is the only way a send that is
/// never answered — the case the deadline exists for — can be produced.
@MainActor
private final class StubFleet: TimelinePaging, PromptSending, PromptAnswering {
    private(set) var requests: [FleetRequest] = []
    private(set) var commands: [FleetCommand] = []
    private var pendingPages: [(Result<TimelinePage, FleetRequestError>) -> Void] = []
    private var pendingAcks: [(Result<Void, FleetRequestError>) -> Void] = []

    /// When set, every command is answered **before `sendPrompt` returns** — the
    /// `.disconnected` path `FleetConnector.send(_:then:)` takes deliberately.
    var answerCommandBeforeReturning: Result<Void, FleetRequestError>?

    var promptTexts: [String] {
        commands.compactMap { if case .prompt(_, _, let t) = $0 { return t } else { return nil } }
    }
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
        if let answer = answerCommandBeforeReturning { return completion(answer) }
        pendingAcks.append(completion)
    }

    /// This file sends messages rather than answers; `SessionTimelineBlockedTests` owns the
    /// answering half. Recorded rather than ignored, so a stray answer shows up here.
    var sent: FleetCommand?

    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        sent = command
    }

    func answerPage(_ result: Result<TimelinePage, FleetRequestError>, line: UInt = #line) {
        guard !pendingPages.isEmpty else {
            return XCTFail("no page was asked for", line: line)
        }
        pendingPages.removeFirst()(result)
    }

    func answerCommand(_ result: Result<Void, FleetRequestError>, line: UInt = #line) {
        guard !pendingAcks.isEmpty else {
            return XCTFail("no command was sent", line: line)
        }
        pendingAcks.removeFirst()(result)
    }
}

/// Sending a message from the phone: what is on screen while it is in flight, what happens
/// when it lands, and what happens when nothing ever comes back.
@MainActor
final class SessionTimelinePromptTests: XCTestCase {
    private let session = UUID()

    private func model(_ fleet: StubFleet, timeout: Duration = .seconds(15))
        -> SessionTimelineModel {
        SessionTimelineModel(sessionID: session, fleet: fleet, timeout: timeout)
    }

    /// Boundaries above and below the items' own offsets, in this file's house style: a page
    /// whose `start` equals its first item's offset cannot catch a cursor bug.
    private func page(_ items: [TimelineItem], start: Int = 1_000, end: Int = 9_000)
        -> TimelinePage {
        TimelinePage(session: session, items: items, start: start, end: end,
                     hasMore: false, reset: false)
    }

    private func turn(_ id: String, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .userTurn, status: .complete, body: .init(text: text))
    }

    func testASentPromptSitsInTheOutboxUntilTheMacAnswers() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")

        XCTAssertEqual(fleet.promptTexts, ["ship it"])
        XCTAssertEqual(model.outbox.entries.map(\.state), [.sending])
        XCTAssertTrue(model.outbox.isSending)
    }

    func testAnAckMovesTheEntryToAcceptedAndAsksForTheTranscript() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.success(()))

        XCTAssertEqual(model.outbox.entries.map(\.state), [.accepted])
        // Nothing else in this app polls a session screen — `loadNewer` has no other caller —
        // so without this fetch the transcript that would retire the entry is never re-read.
        XCTAssertEqual(fleet.requests.count, 1)
    }

    func testTheEntryIsRetiredWhenItsTurnComesBackInAPage() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.success(()))
        fleet.answerPage(.success(page([turn("2000#0", "ship it")])))

        XCTAssertTrue(model.outbox.entries.isEmpty)
    }

    /// The text filed in the outbox is the text that went on the wire, and this is the one
    /// join between the two halves that nothing in `FleetKit` can enforce.
    /// `PromptOutbox.reconcile` matches on exact string equality and `PromptText` strips
    /// trailing newlines before sending, so filing the raw field text would create an entry
    /// no turn could ever match — a row telling the reader their message never landed when
    /// it did.
    func testTheOutboxHoldsTheNormalizedTextThatWasActuallySent() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it\n\n")
        fleet.answerCommand(.success(()))
        fleet.answerPage(.success(page([turn("2000#0", "ship it")])))

        XCTAssertEqual(fleet.promptTexts, ["ship it"])
        XCTAssertTrue(model.outbox.entries.isEmpty, "the entry could never match its own turn")
    }

    /// **The deadline, and it is not belt-and-braces.** Nothing below this model runs a
    /// liveness timer: on a half-open socket — a phone that lost its network path without a
    /// FIN — a pending command sits for the TCP retransmit horizon, which is minutes. A fetch
    /// that vanishes leaves a spinner; a prompt that vanishes leaves a person believing they
    /// told an agent something.
    func testASendThatIsNeverAnsweredFailsAtItsDeadline() async {
        let fleet = StubFleet()
        let model = model(fleet, timeout: .milliseconds(10))
        model.send("ship it")

        let failed = expectation(description: "the deadline fired")
        Task {
            // Polled with a 1ms sleep rather than `Task.yield()`, and that is not a style
            // choice. A bare yield on the main actor is a busy loop, and when this loop does
            // NOT terminate — which is precisely what a regression here looks like — it
            // starves XCTest's own timeout: run in the full bundle against a model whose
            // deadline never fires, the yield version hung the test process for minutes
            // instead of failing at five seconds, and a suite that hangs is worse than one
            // that goes red. A millisecond is well inside the 10ms deadline below.
            while model.outbox.entries.first?.state == .sending {
                try? await Task.sleep(for: .milliseconds(1))
            }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)

        XCTAssertEqual(model.outbox.entries.map(\.state),
                       [.failed(SessionTimelineModel.noConfirmation)])
    }

    /// It does NOT retry, and the copy says so. A timeout cannot distinguish "the Mac never
    /// got it" from "the Mac got it and the ack was lost", and the second is where a silent
    /// retry types the message twice.
    func testATimedOutSendIsNotResent() async {
        let fleet = StubFleet()
        let model = model(fleet, timeout: .milliseconds(10))
        model.send("ship it")

        let failed = expectation(description: "the deadline fired")
        Task {
            // A sleep, not a yield — see the sibling test above.
            while model.outbox.entries.first?.state == .sending {
                try? await Task.sleep(for: .milliseconds(1))
            }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)

        XCTAssertEqual(fleet.promptTexts, ["ship it"], "exactly one send, ever")
    }

    /// Each refusal sends the reader somewhere different, which is why the wire distinguishes
    /// them at all. One generic message would leave someone retyping a message that will
    /// never be taken.
    func testARefusalCarriesTheMacsOwnReason() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.failure(.server(code: "unsupported_agent")))

        XCTAssertEqual(
            model.outbox.entries.map(\.state),
            [.failed("Flight Deck can only type into a Claude session from here.")]
        )
    }

    func testEveryWireCodeThisChannelProducesHasItsOwnSentence() {
        let messages = [
            SessionTimelineModel.promptMessage(for: .disconnected),
            SessionTimelineModel.promptMessage(for: .server(code: "unknown_session")),
            SessionTimelineModel.promptMessage(for: .server(code: "unsupported_agent")),
            SessionTimelineModel.promptMessage(for: .server(code: "not_running")),
            SessionTimelineModel.promptMessage(for: .server(code: "prompt_too_long")),
            SessionTimelineModel.promptMessage(for: .server(code: "prompt_control_characters")),
            SessionTimelineModel.promptMessage(for: .server(code: "prompt_empty")),
        ]
        XCTAssertEqual(Set(messages).count, messages.count,
                       "two codes sharing a sentence is two situations the reader cannot tell apart")
        XCTAssertTrue(
            SessionTimelineModel.promptMessage(for: .server(code: "invented_later"))
                .contains("invented_later"),
            "an unrecognised code must still name itself"
        )
    }

    /// Unsendable text never leaves the phone. The Mac would refuse it anyway; sending it
    /// spends a round trip to tell the user something the composer already knew.
    func testUnsendableTextIsNotSentAtAll() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("   \n  ")
        model.send("go\u{1b}[201~ahead")

        XCTAssertTrue(fleet.commands.isEmpty)
        XCTAssertTrue(model.outbox.entries.isEmpty)
    }

    /// The synchronous-completion path `FleetConnector.send(_:then:)` takes with no socket.
    /// The deadline is armed BEFORE the send for exactly this: armed afterwards it would
    /// outlive an entry that is already failed and fire over the top of it.
    func testADisconnectedSendIsAnsweredWithoutLeavingADeadlineArmed() async {
        let fleet = StubFleet()
        fleet.answerCommandBeforeReturning = .failure(.disconnected)
        let model = model(fleet, timeout: .milliseconds(10))
        model.send("ship it")

        XCTAssertEqual(
            model.outbox.entries.map(\.state),
            [.failed("Not connected to your Mac, so this wasn't sent.")]
        )
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            model.outbox.entries.map(\.state),
            [.failed("Not connected to your Mac, so this wasn't sent.")],
            "a stale deadline must not overwrite the reason the reader is already looking at"
        )
    }

    func testEachSendCarriesItsOwnToken() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("one")
        fleet.answerCommand(.success(()))
        model.send("two")

        XCTAssertEqual(Set(fleet.promptTokens).count, 2,
                       "a shared token would have the Mac dedupe the second message away")
    }

    func testDismissingAFailedEntryClearsIt() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.failure(.server(code: "not_running")))
        let token = try? XCTUnwrap(model.outbox.entries.first?.id)
        model.dismiss(try! XCTUnwrap(token))

        XCTAssertTrue(model.outbox.entries.isEmpty)
    }
}
