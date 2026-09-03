import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A stand-in that answers all three verbs on demand, holding the answer's completion so a
/// test can assert what happens *while* one is outstanding — which is where a second tap and
/// a deadline both live. The same reason `StubFleet` holds its page completion.
@MainActor
private final class StubPager: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
    /// Recorded so a test can assert the screen reports itself; see `viewing(_:)`.
    private(set) var viewingReports: [UUID?] = []
    func viewing(_ session: UUID?) { viewingReports.append(session) }

    private(set) var requests: [FleetRequest] = []
    private var pendingPages: [(Result<TimelinePage, FleetRequestError>) -> Void] = []

    var sent: FleetCommand?
    private var answerCompletion: ((Result<Void, FleetRequestError>) -> Void)?

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
    ) {}

    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        sent = command
        answerCompletion = completion
    }

    /// Answers the oldest outstanding page request, the way the socket resolves a `cid`.
    func answer(_ result: Result<TimelinePage, FleetRequestError>, line: UInt = #line) {
        guard !pendingPages.isEmpty else {
            return XCTFail("nothing was asked for, so there is nothing to answer", line: line)
        }
        pendingPages.removeFirst()(result)
    }

    /// Spins the main actor until a page request is outstanding, then answers it.
    ///
    /// The chase sleeps between attempts, so a test driving it cannot know when the next
    /// request will exist — `answer(_:)` fired too early finds nothing and fails the test for
    /// a timing reason rather than a behavioural one. This waits for the request the chase is
    /// about to make, which is the thing the test actually means.
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

    /// Held rather than answered, so a test can assert what happens WHILE one is outstanding.
    func answerCommand(_ result: Result<Void, FleetRequestError>) {
        let completion = answerCompletion
        answerCompletion = nil
        completion?(result)
    }
}

/// The phone's half of the feature: derive from what it already holds, send one answer at a
/// time, and never claim more than it knows.
@MainActor
final class SessionTimelineBlockedTests: XCTestCase {

    private func makeModel(timeout: Duration = .seconds(15))
        -> (SessionTimelineModel, StubPager) {
        let stub = StubPager()
        return (
            SessionTimelineModel(sessionID: UUID(), fleet: stub, timeout: timeout), stub
        )
    }

    private func page(_ items: [TimelineItem], session: UUID) -> TimelinePage {
        TimelinePage(session: session, items: items, start: 0, end: 1_000,
                     hasMore: false, reset: false)
    }

    /// A real `AskUserQuestion` input, in the shape claude 2.1.241 writes it — the same body
    /// `ClaudeTimelineMapper` puts in a `.prompt` row.
    private func askItem(callID: String) -> TimelineItem {
        TimelineItem(
            id: "\(abs(callID.hashValue % 90_000) + 1_000)#0", kind: .prompt, status: .complete,
            body: .init(
                text: #"""
                    {
                      "questions" : [
                        {
                          "header" : "Pick",
                          "multiSelect" : false,
                          "options" : [
                            {
                              "description" : "The first one.",
                              "label" : "Yes"
                            },
                            {
                              "description" : "The second one.",
                              "label" : "No"
                            }
                          ],
                          "question" : "Which?"
                        }
                      ]
                    }
                    """#,
                tool: "AskUserQuestion", callID: callID
            )
        )
    }

    private func resultItem(callID: String) -> TimelineItem {
        TimelineItem(
            id: "\(abs(callID.hashValue % 90_000) + 91_000)#0", kind: .toolResult,
            status: .complete,
            body: .init(text: "Yes", tool: "AskUserQuestion", callID: callID)
        )
    }

    /// **Derived, not fetched.** The whole question comes out of the feed the screen already
    /// has — this test would need a second round trip if any of it were transmitted.
    func testAQuestionIsDerivedFromTheFeedTheScreenAlreadyHolds() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        guard case .question("toolu_A", let questions)? =
            model.blocked(agent: "claude", activity: "waiting", call: .unreported)
        else { return XCTFail("expected a question") }
        XCTAssertEqual(questions.count, 1, "this fixture asks one")
        XCTAssertEqual(questions[0].options.map(\.label), ["Yes", "No"])
    }

    /// **No card for an agent nothing can answer for.** The feed here is claude-shaped and
    /// holds a genuinely open call — the identical feed draws a card one line below — so what
    /// this asserts is the agent gate and not an empty feed. A codex tab that reported
    /// `waiting` would otherwise draw Allow/Deny built from claude's dialog grammar, over
    /// claude's row ordering, whose answer comes back `unsupported_agent`: an offer that
    /// cannot be honoured, which is worse than no offer at all.
    func testACodexTabIsBlockedOnNothingEvenWithAnOpenCallOnScreen() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        XCTAssertNil(model.blocked(agent: "codex", activity: "waiting", call: .unreported))
        XCTAssertNotNil(
            model.blocked(agent: "claude", activity: "waiting", call: .unreported),
            "the same feed must still block a claude tab, or this is asserting the feed"
        )
    }

    /// An agent added after this build shipped is not given claude's dialog either — the
    /// `WireSession.subagentSummary` rule, applied to a whole card.
    func testAnUnknownAgentIsBlockedOnNothing() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        for agent in [nil, "", "gemini"] as [String?] {
            XCTAssertNil(
                model.blocked(agent: agent, activity: "waiting", call: .unreported),
                "agent \(String(describing: agent))"
            )
        }
    }

    func testNothingIsBlockedWhileTheSessionIsNotWaiting() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        XCTAssertNil(model.blocked(agent: "claude", activity: "busy", call: .unreported))
        XCTAssertNil(model.blocked(agent: "claude", activity: nil, call: .unreported))
    }

    /// **The Mac answered first.** The result arrives on the next fetch, and the card is gone
    /// — with no new frame, no push, and nothing to invalidate.
    func testAResultArrivingOnALaterPageClearsTheBlock() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        XCTAssertNotNil(model.blocked(agent: "claude", activity: "waiting", call: .unreported))
        model.loadNewer()
        stub.answer(.success(page(
            [askItem(callID: "toolu_A"), resultItem(callID: "toolu_A")], session: model.sessionID
        )))
        XCTAssertNil(model.blocked(agent: "claude", activity: "waiting", call: .unreported))
    }

    func testTappingAnOptionSendsAnAnswerNamingTheCall() {
        let (model, stub) = makeModel()
        model.answer(.option(index: 1, label: "No"), to: "toolu_A")
        guard case .answerPrompt(let id, _, let call, let answer)? = stub.sent
        else { return XCTFail("expected an answer command") }
        XCTAssertEqual(id, model.sessionID)
        XCTAssertEqual(call, "toolu_A")
        XCTAssertEqual(answer, .option(index: 1, label: "No"))
        XCTAssertEqual(model.answerState, .sent(call: "toolu_A"))
    }

    /// One in flight at a time. A second tap before the first ack must not become two answers
    /// — which, on a permission dialog, is two decisions.
    func testASecondTapWhileOneIsInFlightSendsNothing() {
        let (model, stub) = makeModel()
        model.answer(.allow, to: "toolu_A")
        stub.sent = nil
        model.answer(.deny, to: "toolu_A")
        XCTAssertNil(stub.sent)
    }

    /// A new call clears a stuck state, so a card that failed on the previous dialog does not
    /// suppress the next one's controls.
    func testAnAnswerToANewCallIsAllowedAfterAFailure() {
        let (model, stub) = makeModel()
        model.answer(.allow, to: "toolu_ONE")
        stub.answerCommand(.failure(.server(code: "prompt_changed")))
        stub.sent = nil
        model.answer(.allow, to: "toolu_TWO")
        XCTAssertNotNil(stub.sent)
    }

    func testAnAckLeavesTheCardSayingItWasSent() {
        let (model, stub) = makeModel()
        model.answer(.deny, to: "toolu_A")
        stub.answerCommand(.success(()))
        XCTAssertEqual(model.answerState, .sent(call: "toolu_A"))
    }

    func testARefusalIsShownWithTheMacsOwnReason() {
        let (model, stub) = makeModel()
        model.answer(.allow, to: "toolu_A")
        stub.answerCommand(.failure(.server(code: "prompt_changed")))
        XCTAssertEqual(
            model.answerState,
            .failed(call: "toolu_A",
                    SessionTimelineModel.answerMessage(for: .server(code: "prompt_changed")))
        )
    }

    /// **The silent failure this deadline exists for.** `ack` means dispatched, and the Mac's
    /// driver refuses to press Return on a screen it cannot confirm — so a dispatched answer
    /// that never landed produces no frame at all. A half-open socket produces none either.
    func testAnAnswerNobodyConfirmsBecomesAFailureOnTheDeadline() async {
        let (model, _) = makeModel(timeout: .milliseconds(20))
        model.answer(.allow, to: "toolu_A")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            model.answerState,
            .failed(call: "toolu_A", SessionTimelineModel.noAnswerConfirmation)
        )
    }

    /// Deliberately not "try again". A retry after a timeout is the one action that can press
    /// Return twice — and on a permission dialog, approve twice.
    ///
    /// **Not a ban on the word "again"**, which is what this task's brief asked for and what
    /// the specified copy — "…before answering again", the same conditional the composer's
    /// `noConfirmation` ends on — cannot satisfy. The discipline is not that the word is
    /// forbidden but that the retry is never offered *unconditionally*: what the reader is
    /// told to do first is look at the terminal. "Your Mac didn't confirm this. Try again."
    /// kills both halves of this.
    func testTheUnconfirmedCopyDoesNotInviteARetryWithoutLookingFirst() {
        let copy = SessionTimelineModel.noAnswerConfirmation.lowercased()
        XCTAssertFalse(copy.contains("try again"))
        guard let look = copy.range(of: "terminal"), let again = copy.range(of: "again")
        else { return XCTFail("the copy must send the reader to the terminal before a retry") }
        XCTAssertLessThan(look.lowerBound, again.lowerBound)
    }

    // MARK: The card that never arrived

    /// **The race this closes, and why one retry was not enough.** claude writes its status
    /// file and its transcript by independent paths, so `waiting` can arrive before the record
    /// that says what the session is waiting ON. The screen used to cover that with a single
    /// deferred fetch — and when that one lost, nothing fired again: a waiting session emits no
    /// further activity change, the busy poll runs only while busy, and the card never came.
    /// The session sat saying "Waiting for you" with nothing to answer, for as long as it was
    /// blocked. Intermittent by construction, which is why it read as "sometimes".
    func testAPromptThatLandsLateIsStillFoundRatherThanWaitedOnForever() async {
        let (model, stub) = makeModel()
        model.promptRetries = Array(repeating: .milliseconds(30), count: 5)
        model.loadLatest()
        stub.answer(.success(page([], session: model.sessionID)))
        XCTAssertNil(model.blocked(agent: "claude", activity: "waiting", call: .unreported),
                     "the premise: no card")

        async let chase: Void = model.chaseBlockedPrompt(
            agent: "claude", activity: "waiting", call: .unreported
        )
        // The record lands on the second look, the way a transcript written a beat late does.
        await stub.answerWhenAsked(.success(page([], session: model.sessionID)))
        await stub.answerWhenAsked(
            .success(page([askItem(callID: "toolu_late")], session: model.sessionID))
        )
        await chase

        XCTAssertNotNil(model.blocked(agent: "claude", activity: "waiting", call: .unreported),
                        "the card is there once the record is")
    }

    /// **It must cost nothing in the ordinary case.** Most of the time the record is already in
    /// the feed when `waiting` arrives, and a screen that fetched anyway would spend a round
    /// trip per blocked session for no reason.
    func testAPromptAlreadyOnScreenIsNeverChasedAtAll() async {
        let (model, stub) = makeModel()
        model.promptRetries = Array(repeating: .milliseconds(30), count: 5)
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_here")], session: model.sessionID)))
        let asked = stub.requests.count

        await model.chaseBlockedPrompt(agent: "claude", activity: "waiting", call: .unreported)

        XCTAssertEqual(stub.requests.count, asked, "nothing was asked for")
    }

    /// **And it gives up.** A blocked session can sit for an hour, so the chase is capped: a
    /// record that never arrives — a codex tab, a body this build cannot parse — must not turn
    /// into a poll that runs for the life of the screen. This is the objection the one-shot
    /// version was written to avoid, answered with a bound rather than with a single try.
    func testAChaseThatNeverFindsAnythingStopsRatherThanPollingForever() async {
        let (model, stub) = makeModel()
        model.promptRetries = Array(repeating: .milliseconds(30), count: 3)
        model.loadLatest()
        stub.answer(.success(page([], session: model.sessionID)))
        let before = stub.requests.count

        async let chase: Void = model.chaseBlockedPrompt(
            agent: "claude", activity: "waiting", call: .unreported
        )
        for _ in 0..<3 { await stub.answerWhenAsked(.success(page([], session: model.sessionID))) }
        await chase

        XCTAssertEqual(stub.requests.count - before, 3, "three attempts, then it stops")
        XCTAssertNil(model.blocked(agent: "claude", activity: "waiting", call: .unreported))
    }

    // MARK: The phone's own verdict

    /// **Exhaustion is the phone's own diagnosis, not only a stopping rule.** Running the whole
    /// schedule out with nothing to show is what separates this session from the ordinary race
    /// every other blocked session rides out inside the early retries — see
    /// `blockedChaseExhausted`'s own comment for why the first miss must not set this.
    func testExhaustingTheChaseMarksTheSessionBlocked() async {
        let (model, stub) = makeModel()
        model.promptRetries = Array(repeating: .milliseconds(30), count: 3)
        model.loadLatest()
        stub.answer(.success(page([], session: model.sessionID)))

        async let chase: Void = model.chaseBlockedPrompt(
            agent: "claude", activity: "waiting", call: .unreported
        )
        for _ in 0..<3 { await stub.answerWhenAsked(.success(page([], session: model.sessionID))) }
        await chase

        XCTAssertTrue(model.blockedChaseExhausted)
    }

    /// **The discriminating half of the pair above.** A model that always set the flag would
    /// pass the exhaustion test and fail this one: the card is already on screen before the
    /// chase's first look, so the schedule never even reaches its second attempt.
    func testACardArrivingBeforeTheScheduleRunsOutLeavesItUnblocked() async {
        let (model, stub) = makeModel()
        model.promptRetries = Array(repeating: .milliseconds(30), count: 5)
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_here")], session: model.sessionID)))

        await model.chaseBlockedPrompt(agent: "claude", activity: "waiting", call: .unreported)

        XCTAssertFalse(model.blockedChaseExhausted)
    }

    /// **The flag resets on every entry, not just once.** `SessionTimelineScreen` re-invokes
    /// `chaseBlockedPrompt` from a `.task(id:)` keyed on the blocked dialog, so a session that
    /// stalled once and then moved on must not go on reporting the stall that is over.
    func testANewChaseClearsAPreviousExhaustion() async {
        let (model, stub) = makeModel()
        model.promptRetries = Array(repeating: .milliseconds(30), count: 2)
        model.loadLatest()
        stub.answer(.success(page([], session: model.sessionID)))

        async let firstChase: Void = model.chaseBlockedPrompt(
            agent: "claude", activity: "waiting", call: .unreported
        )
        for _ in 0..<2 { await stub.answerWhenAsked(.success(page([], session: model.sessionID))) }
        await firstChase
        XCTAssertTrue(model.blockedChaseExhausted, "the premise: the first chase exhausted")

        model.promptRetries = Array(repeating: .milliseconds(30), count: 2)
        async let secondChase: Void = model.chaseBlockedPrompt(
            agent: "claude", activity: "waiting", call: .call("toolu_new")
        )
        await stub.answerWhenAsked(
            .success(page([askItem(callID: "toolu_new")], session: model.sessionID))
        )
        await secondChase

        XCTAssertFalse(model.blockedChaseExhausted)
    }

    // MARK: - What the Mac says is open

    /// **The stale card, from this end.** The feed still holds `toolu_A` unanswered — the
    /// derivation on its own is perfectly happy — but the Mac's status now names `toolu_B`,
    /// which is claude having answered one dialog and raised the next without the session
    /// leaving `waiting`. Drawing A's question here is drawing a dialog nobody is being asked,
    /// with buttons whose answer comes back `prompt_changed`. Nothing is better.
    func testADialogTheMacNoLongerNamesIsNotDrawn() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        XCTAssertNotNil(
            model.blocked(agent: "claude", activity: "waiting", call: .call("toolu_A")),
            "the premise: while the Mac agrees, the card is drawn"
        )

        XCTAssertNil(model.blocked(agent: "claude", activity: "waiting", call: .call("toolu_B")))
    }

    /// The other half: the Mac is still `waiting` but can name no dialog at all — answered at
    /// the keyboard, or a dialog this build cannot read. `activity` says nothing has changed,
    /// so before this field the card simply stayed.
    func testNoDialogNamedMeansNoCardEvenWhileWaiting() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))

        XCTAssertNil(model.blocked(agent: "claude", activity: "waiting", call: .noPrompt))
    }

    /// **A Mac too old to send the field gets today's behaviour.** `.unreported` is the state
    /// that defers to this end, and it has to: reading an absent key as "no dialog" would hide
    /// every card the phone can still draw, which is a worse regression than the stale card
    /// and one a reader has no way out of.
    func testAMacThatReportsNothingIsStillTrustedToBeBlocked() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))

        XCTAssertNotNil(model.blocked(agent: "claude", activity: "waiting", call: .unreported))
    }

    /// The chase covers a *changed* dialog and not only a late one: a Mac naming a call this
    /// feed has never seen reads exactly like a record that has not arrived yet, because that
    /// is what it is. Without this the card would stay blank until something else moved.
    func testAChaseRunsUntilTheDialogTheMacNamesArrives() async {
        let (model, stub) = makeModel()
        model.promptRetries = Array(repeating: .milliseconds(30), count: 5)
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))

        async let chase: Void = model.chaseBlockedPrompt(
            agent: "claude", activity: "waiting", call: .call("toolu_B")
        )
        await stub.answerWhenAsked(.success(page(
            [askItem(callID: "toolu_A"), resultItem(callID: "toolu_A"),
             askItem(callID: "toolu_B")],
            session: model.sessionID
        )))
        await chase

        guard case .question("toolu_B", _)? =
            model.blocked(agent: "claude", activity: "waiting", call: .call("toolu_B"))
        else { return XCTFail("expected the dialog the Mac named") }
    }
}
