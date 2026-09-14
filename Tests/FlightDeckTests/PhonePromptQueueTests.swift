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

    /// A busy tab whose input box holds a MULTI-ROW draft, so the queue still forms.
    ///
    /// `submit` types AROUND a one-row draft now — kill, type, yank it back — so a single line
    /// no longer holds a prompt. A draft spanning rows still defers: Ctrl+U kills one logical
    /// line and yank-pop replaces rather than appends, so a multi-row draft cannot be taken
    /// apart and put back, and `submit` refuses it untouched (see
    /// `SessionRenameTests.testRenameDefersWhileTheDraftSpansMultipleRows`). That refusal is
    /// what holds the prompt for the queue-MECHANICS tests below — ordering, expiry, a close
    /// dropping the queue — none of which are about the typing rule itself.
    private func makeBusyStoreThatHoldsTheQueue() -> (SessionStore, SpyInjector, UUID, UUID) {
        let made = makeStore(activity: .busy)
        made.1.typeDraft(["half a thought", "and the rest of it"])
        made.1.events.removeAll()
        return made
    }

    /// A busy tab whose input box holds a ONE-ROW draft — the case the kill-probe types AROUND
    /// rather than defers. Used only where the probe itself (kill, type, restore) is under test.
    private func makeBusyStoreWithAOneRowDraft() -> (SessionStore, SpyInjector, UUID, UUID) {
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

    /// **A one-row draft is typed AROUND, not deferred.** `submit` kills the line to probe the
    /// box, types the prompt — the agent queues text typed mid-turn, which is what a person at
    /// the keyboard relies on — and then yanks the draft back out of the kill-ring so the
    /// half-written thought reappears behind it. Deferring on any draft (an earlier cut) also
    /// refused to type into idle boxes, because an idle box's rotating placeholder reads as a
    /// draft — which broke 100% of sidebar renames.
    func testAPromptSentMidTurnIntoAOneRowDraftIsTypedAndRestoresTheDraft() {
        let (store, spy, id, _) = makeBusyStoreWithAOneRowDraft()
        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertEqual(spy.events, [.killLine, .text("ship it"), .ret, .yank],
                       "type the prompt, then put the draft straight back")
        XCTAssertEqual(spy.sent, ["ship it"], "typed around the draft")
        XCTAssertNil(store.promptQueue[id], "typed, so nothing waits")
    }

    /// **Rewritten, not merely inverted.** `inject` no longer reads activity at all, so what
    /// has to refuse a dialog is the SCREEN: a real captured permission prompt, which draws
    /// its own `❯` but never the rule immediately above it that a genuine composer does (see
    /// `ClaudeTextChannel.isComposerBox`). `.waiting` is set anyway, for realism, but the
    /// viewport is what does the work.
    func testAPromptToAWaitingTabIsHeldAndNeverTyped() throws {
        let (store, spy, id, _) = makeStore(activity: .waiting)
        spy.viewportOverride = try TimelineFixtureTests.text("permission-bash.captured", in: "Claude")
        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertTrue(spy.events.isEmpty, "nothing may be typed at a dialog")
        XCTAssertNotNil(store.promptQueue[id], "held, not discarded")
    }

    /// **What frees the box is the draft clearing, not the turn ending.** A multi-row draft
    /// defers the prompt (`submit` will not type over one), so the queue drains when the user
    /// submits or clears what was in the bar — modelled here by emptying it — and the next
    /// registry scan types the prompt.
    func testAQueuedPromptIsTypedOnceTheBoxClears() {
        let (store, spy, id, conversation) = makeBusyStoreThatHoldsTheQueue()
        store.submitPrompt("ship it", token: UUID(), to: id)
        spy.buffer = ""                                     // user submitted or cleared the draft
        spy.renderedRows = ["❯"]
        goIdle(store, conversation)
        XCTAssertEqual(spy.sent, ["ship it"])
        XCTAssertNil(store.promptQueue[id])
    }

    /// **The supersession test, and the reason this queue is not `pendingPrompts`.**
    /// `cancelSupersededPrompts` drops a resume prompt the moment a session starts working,
    /// which is right for "Keep going" and catastrophic for a message a person typed: their
    /// words would vanish at exactly the transition they sent them across.
    func testAQueuedPromptSurvivesTheAgentGoingBusy() {
        let (store, _, id, _) = makeBusyStoreThatHoldsTheQueue()
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
        let (store, spy, id, conversation) = makeBusyStoreThatHoldsTheQueue()
        store.submitPrompt("first", token: UUID(), to: id)
        store.submitPrompt("second", token: UUID(), to: id)
        XCTAssertEqual(store.promptQueue[id]?.map(\.text), ["first", "second"])

        spy.buffer = ""                                     // user submitted or cleared the draft
        spy.renderedRows = ["❯"]
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

    /// **The restore is owed even when the request is abandoned mid-settle.** A one-row draft is
    /// killed to probe the box; if the request is superseded — here the tab closes — while
    /// claude repaints, the settle must STILL yank the draft back out of the kill-ring. Gating
    /// the restore on the same `stillWanted` re-check that guards the typing (as an earlier cut
    /// did) destroyed the very draft the kill-probe exists to protect: Ctrl+U had already gone
    /// out, and the abandoned settle returned without the Ctrl+Y. Restore first, decide second.
    func testAKilledDraftIsRestoredEvenWhenTheRequestIsAbandonedDuringTheSettle() {
        let (store, spy, id, _) = makeBusyStoreWithAOneRowDraft()
        var settle: (() -> Void)?
        store.injectionSettle = { settle = $0 }
        store.submitPrompt("ship it", token: UUID(), to: id)
        XCTAssertEqual(spy.events, [.killLine],
                       "the kill goes out before the settle; nothing else has yet")

        store.closeSession(id)          // supersedes the request: stillWanted() is now false
        settle?()
        XCTAssertEqual(spy.events, [.killLine, .yank], "the draft is restored, not abandoned")
        XCTAssertTrue(spy.sent.isEmpty, "and nothing is typed")
    }

    /// A window, for the reason `resumePromptWindow` has one, and a longer one because a
    /// claude turn running a test suite outlives two minutes routinely.
    func testAnExpiredPromptIsDroppedUnsent() {
        let (store, spy, id, conversation) = makeBusyStoreThatHoldsTheQueue()
        store.submitPrompt("ship it", token: UUID(), to: id)
        store.now = { [clock] in clock.addingTimeInterval(SessionStore.phonePromptWindow + 1) }

        goIdle(store, conversation)
        // A multi-row draft is refused before any keystroke, so nothing was ever SENT; the point
        // is that the prompt is now dropped for having expired.
        XCTAssertTrue(spy.sent.isEmpty)
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
        let (store, _, id, conversation) = makeBusyStoreThatHoldsTheQueue()
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
        let (store, _, id, _) = makeBusyStoreThatHoldsTheQueue()
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
        let (store, _, id, conversation) = makeBusyStoreThatHoldsTheQueue()
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
        let (store, spy, id, conversation) = makeBusyStoreThatHoldsTheQueue()
        store.submitPrompt("ship it", token: UUID(), to: id)
        store.rename(id, to: "renamed")
        // An idle status without a tick, so nothing flushes the rename. The multi-row draft in
        // the bar defers both the rename and the prompt, and the `pendingRenames` guard keeps
        // the prompt behind the rename — so the assertion below is worth something because the
        // rename is the one thing left to land first.
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle, waitingFor: nil)])
        store.flushPromptQueueForTesting()
        // A multi-row draft is refused before any keystroke, so nothing has been SENT and the
        // prompt is still queued — the rename has yet to land, and the prompt is behind it.
        XCTAssertTrue(spy.sent.isEmpty, "nothing lands over the draft, rename or prompt")
        XCTAssertEqual(store.promptQueue[id]?.map(\.text), ["ship it"],
                       "yielding to the rename defers the prompt, it does not drop it")

        spy.buffer = ""                                     // user submitted or cleared the draft
        spy.renderedRows = ["❯"]
        goIdle(store, conversation)
        XCTAssertEqual(spy.sent, ["/rename renamed", "ship it"],
                       "the rename goes first and the prompt follows it")
    }
}
