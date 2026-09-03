import XCTest
@testable import FleetKit
@testable import FlightDeck

/// A prompt that arrives while the agent is mid-turn — which is the ordinary case, not the
/// edge one, because mid-turn is when a person reaches for their phone.
@MainActor
final class PhonePromptQueueTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    private let clock = Date(timeIntervalSince1970: 1_000_000)

    /// A busy tab whose input box already holds a draft, so the queue still forms.
    ///
    /// Typing mid-turn is allowed now, into an EMPTY box only — the agent queues it, which is
    /// what a person at the keyboard relies on. So a test about queue MECHANICS (ordering,
    /// expiry, a close dropping the queue) needs the other half of that rule to hold the
    /// prompt: something already in the box. The draft is what makes these tests still about
    /// what they were about.
    private func makeBusyStoreWithADraft() -> (SessionStore, SpyInjector, UUID, UUID) {
        let made = makeStore(activity: .busy)
        made.1.typeDraft(["half a thought"])
        made.1.events.removeAll()
        return made
    }

    private func makeStore(activity: SessionActivity = .busy)
        -> (SessionStore, SpyInjector, UUID, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.statusRootOverride = projectsRoot
        store.now = { [clock] in clock }
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id, session.pinnedConversationID)
    }

    private func goIdle(_ store: SessionStore, _ conversation: UUID) {
        store.applyRegistry([1: entry(conversation, .idle, cwd: tmp.path)])
    }

    /// The tick during the turn, which no other test here arranges: a turn spans many
    /// registry scans, and every one of them runs this flush. An entry has to come through
    /// each of them still queued — neither typed into the running turn nor quietly retired by
    /// a flush that read `inject`'s refusal as an answer.
    /// **Mid-turn typing, into an empty box.** The agent has its own prompt queue and takes
    /// input while it works — that is what a person at the keyboard relies on — so a prompt
    /// from the phone goes in the same way rather than waiting for an idle that may never
    /// come. Waiting was how a message could be accepted, held, and destroyed at
    /// `phonePromptWindow` having never been typed.
    func testAPromptSentMidTurnIsTypedIntoAnEmptyBox() {
        let (store, spy, id, _) = makeStore(activity: .busy)
        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertFalse(spy.events.isEmpty, "a busy tab with an empty box takes it now")
        XCTAssertNil(store.promptQueue[id], "nothing waits for an idle that may never come")
    }

    /// **The other half, and the reason the rule is not just "type mid-turn".** `submit`
    /// restores a draft by killing and yanking it back, which depends on reading a settled
    /// screen. Mid-turn the screen is repainting, so a box with something in it is deferred
    /// rather than risked — someone's half-written thought is not ours to gamble with.
    func testAPromptSentMidTurnWaitsWhenTheBoxHasADraft() {
        let (store, spy, id, _) = makeBusyStoreWithADraft()
        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertTrue(spy.events.isEmpty, "a draft is not clobbered mid-turn")
        XCTAssertNotNil(store.promptQueue[id], "held until the box is free")
    }

    func testAPromptToAWaitingTabIsHeldAndNeverTyped() {
        let (store, spy, id, _) = makeStore(activity: .waiting)
        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertTrue(spy.events.isEmpty, "nothing may be typed at a dialog")
        XCTAssertNotNil(store.promptQueue[id], "held, not discarded")
    }

    func testAQueuedPromptIsTypedOnceTheTurnEnds() {
        let (store, spy, id, conversation) = makeBusyStoreWithADraft()
        store.submitPrompt("ship it", token: UUID(), to: id)
        goIdle(store, conversation)
        XCTAssertEqual(spy.sent, ["ship it"])
        XCTAssertNil(store.promptQueue[id])
    }

    /// **The supersession test, and the reason this queue is not `pendingPrompts`.**
    /// `cancelSupersededPrompts` drops a resume prompt the moment a session starts working,
    /// which is right for "Keep going" and catastrophic for a message a person typed: their
    /// words would vanish at exactly the transition they sent them across.
    func testAQueuedPromptSurvivesTheAgentGoingBusy() {
        let (store, _, id, _) = makeBusyStoreWithADraft()
        store.submitPrompt("ship it", token: UUID(), to: id)
        store.cancelSupersededPromptsForTesting([
            StatusTransition(id: id, old: nil,
                             new: SessionStatus(activity: .busy, waitingFor: nil))
        ])
        XCTAssertEqual(store.promptQueue[id]?.map(\.text), ["ship it"],
                       "a message a person typed is not superseded by the agent getting busy")
    }

    /// Two messages are two messages, in order. Distinct texts, and the ORDER asserted, so a
    /// LIFO or a dictionary-backed store fails rather than passing on a count.
    func testTwoPromptsAreTypedInOrderOneTickApart() {
        let (store, spy, id, conversation) = makeBusyStoreWithADraft()
        store.submitPrompt("first", token: UUID(), to: id)
        store.submitPrompt("second", token: UUID(), to: id)
        XCTAssertEqual(store.promptQueue[id]?.map(\.text), ["first", "second"])

        goIdle(store, conversation)
        XCTAssertEqual(spy.sent, ["first"], "one per pass — the second would land on a bar "
                       + "that has just started a turn")
        store.flushPromptQueueForTesting()
        XCTAssertEqual(spy.sent, ["first", "second"])
        XCTAssertNil(store.promptQueue[id])
    }

    /// The re-check after the settle, which this suite's synchronous `injectionSettle` is
    /// otherwise unable to see: production settles a run-loop turn later, and a tab can be
    /// closed — or its entry expire — while claude repaints. So this fixture holds the settle
    /// open and closes the tab underneath it. Ctrl+U has already gone out by then; what must
    /// not follow it is the user's words, typed at whatever occupies that surface now.
    func testATabClosedDuringTheSettleIsNotTypedInto() {
        let (store, spy, id, conversation) = makeStore(activity: .busy)
        var settle: (() -> Void)?
        store.injectionSettle = { settle = $0 }
        store.submitPrompt("ship it", token: UUID(), to: id)

        goIdle(store, conversation)
        XCTAssertEqual(spy.events, [.killLine],
                       "the kill goes out before the settle; nothing else has yet")

        store.closeSession(id)
        settle?()
        XCTAssertEqual(spy.sent, [], "the tab those words were meant for is gone")
    }

    /// A window, for the reason `resumePromptWindow` has one, and a longer one because a
    /// claude turn running a test suite outlives two minutes routinely.
    func testAnExpiredPromptIsDroppedUnsent() {
        let (store, spy, id, conversation) = makeBusyStoreWithADraft()
        store.submitPrompt("ship it", token: UUID(), to: id)
        store.now = { [clock] in clock.addingTimeInterval(SessionStore.phonePromptWindow + 1) }

        goIdle(store, conversation)
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertNil(store.promptQueue[id])
    }

    /// **Dropping it is right; dropping it silently was not.** The window is deliberate — a
    /// message surfacing hours later in a conversation that has moved on is worse than one
    /// that never arrived — but the phone was told `.queued` at submit time and then nothing
    /// ever contradicted that, so its outbox row sat at "Waiting for your Mac to type this"
    /// for a prompt that no longer existed on either machine.
    ///
    /// The token is what carries the news, because the token is what the phone's outbox is
    /// keyed on; the text is already over there.
    func testAnExpiredPromptTellsThePhoneItWasDropped() {
        let (store, _, id, conversation) = makeBusyStoreWithADraft()
        let replicator = attachedReplicator(to: store)
        let token = UUID()
        store.submitPrompt("ship it", token: token, to: id)
        store.now = { [clock] in clock.addingTimeInterval(SessionStore.phonePromptWindow + 1) }

        goIdle(store, conversation)

        XCTAssertTrue(
            replicator.recorded.contains { $0 == .promptExpired(id: id, token: token) },
            "an expired prompt must be reported, not merely forgotten"
        )
    }

    /// The other half, and the one a careless implementation breaks: a prompt that WAS typed
    /// must never be reported as expired. `onSent` and the expiry filter both remove the same
    /// entry, and reporting from the wrong one would tell the reader their delivered message
    /// was lost.
    func testAPromptThatWasTypedIsNotReportedAsExpired() {
        let (store, _, id, conversation) = makeStore(activity: .busy)
        let replicator = attachedReplicator(to: store)
        let token = UUID()
        store.submitPrompt("ship it", token: token, to: id)

        goIdle(store, conversation)

        XCTAssertNil(store.promptQueue[id], "it was typed")
        XCTAssertFalse(
            replicator.recorded.contains { if case .promptExpired = $0 { return true }
                                           else { return false } },
            "a delivered prompt must not be reported as dropped"
        )
    }

    func testTheWindowIsLongerThanAResumePrompts() {
        XCTAssertGreaterThan(SessionStore.phonePromptWindow, SessionStore.resumePromptWindow)
    }

    /// Closing the tab is the most literal case of "a prompt that will never be typed".
    func testClosingATabDropsItsQueue() {
        let (store, _, id, _) = makeBusyStoreWithADraft()
        store.submitPrompt("ship it", token: UUID(), to: id)
        XCTAssertNotNil(store.promptQueue[id])

        store.closeSession(id)
        XCTAssertNil(store.promptQueue[id])
        XCTAssertEqual(store.submitPrompt("again", token: UUID(), to: id), .unknownSession)
    }

    /// The other half of the same guard, and the sharper half: what `pendingPrompts` holds —
    /// a restore's "Keep going", a sign-in's `/login` — has two minutes to live where this
    /// queue has fifteen, so the entry that can still be missed goes first. Asserted at
    /// submit time, on an IDLE tab whose every other gate is open, so the pending `/login` is
    /// the only thing standing between the phone's words and the bar.
    func testAPendingResumePromptGoesFirst() {
        let (store, spy, _, _) = makeStore(activity: .busy)
        let signIn = store.openSignInSession(
            for: AgentAccount(agent: .claude, displayName: "Work",
                              home: projectsRoot.appendingPathComponent("Work")),
            in: tmp.path, using: LoginInvocation(command: "claude", inject: "/login")
        )
        // Idle rather than busy on purpose: `cancelSupersededPrompts` would drop the
        // `/login` on any other transition, and an idle tab is where a stray injection
        // actually reaches the pty.
        store.applyRegistryForTesting([signIn.id: SessionStatus(activity: .idle, waitingFor: nil)])
        XCTAssertNotNil(store.pendingPrompts[signIn.id], "the fixture needs the /login pending")
        spy.events.removeAll()

        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: signIn.id), .queued,
                       "idle, and still queued: the /login owns the bar")
        XCTAssertTrue(spy.events.isEmpty)

        store.flushPendingResumePromptsForTesting()
        XCTAssertEqual(spy.sent, ["/login"])
        store.flushPromptQueueForTesting()
        XCTAssertEqual(spy.sent, ["/login", "ship it"])
    }

    /// The tokens go with the tab, which `acceptedPromptTokens` promises and only this
    /// asserts. A reopened tab comes back on the closed one's id, so a dedupe window left
    /// behind would answer `.duplicate` — an ack — to a genuinely new message whose token the
    /// dead session happened to have seen, and the phone would call a send landed that never
    /// was.
    func testAReopenedTabDoesNotInheritTheClosedOnesTokens() {
        let (store, _, id, conversation) = makeBusyStoreWithADraft()
        store.titleResolver = { _, _, done in done(nil) }
        store.launchFailureReporter = SilentReporter()
        let token = UUID()
        XCTAssertEqual(store.submitPrompt("ship it", token: token, to: id), .queued)

        store.closeSession(id)
        store.reopenLastClosed(directoryExists: { _ in true })
        // The reopened tab is the same id on the same conversation, so the same registry row
        // gives it its status back.
        store.applyRegistry([1: entry(conversation, .busy, cwd: tmp.path)])

        XCTAssertEqual(store.submitPrompt("ship it", token: token, to: id), .queued,
                       "the dedupe window belonged to the session that is over")
    }

    /// A rename is a direct user action on the same input box and clears within a tick or
    /// two; a queued prompt can wait for it, and waiting costs nothing.
    ///
    /// The pending rename is arranged by hand rather than left to `goIdle`, because this
    /// fixture's `injectionSettle` is synchronous: a rename driven by the tick is typed AND
    /// retired inside the same `defer` that flushes this queue, so the guard would read a
    /// `pendingRenames` that is already empty and the test would prove nothing. Production
    /// settles on a later turn of the run loop, where the rename is still pending when the
    /// same tick reaches this queue — which is the state the two lines below reproduce.
    func testAPendingRenameGoesFirst() {
        let (store, spy, id, conversation) = makeBusyStoreWithADraft()
        store.submitPrompt("ship it", token: UUID(), to: id)
        store.rename(id, to: "renamed")
        // An idle status without a tick, so nothing flushes the rename. Every other gate
        // `inject` has is now open — idle status, a readable one-row bar, an injector — so
        // the assertion below is only worth something because the rename is the one thing
        // left refusing.
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle, waitingFor: nil)])
        store.flushPromptQueueForTesting()
        XCTAssertTrue(spy.events.isEmpty, "the rename owns the bar until it has landed")
        XCTAssertEqual(store.promptQueue[id]?.map(\.text), ["ship it"],
                       "yielding to the rename defers the prompt, it does not drop it")

        goIdle(store, conversation)
        XCTAssertEqual(spy.sent, ["/rename renamed", "ship it"],
                       "the rename goes first and the prompt follows it")
    }
}
