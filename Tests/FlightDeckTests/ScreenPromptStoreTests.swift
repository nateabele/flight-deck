import IntakeKit
import XCTest
@testable import FleetKit
@testable import FlightDeck

/// A `waiting` claude tab whose transcript names nothing, and whose screen does — the half of
/// the feature that lives in `SessionStore`: when the Mac offers a screen dialog, and what it
/// does with a phone's answer to one.
///
/// **The answer cases assert the ORDER of what was pressed**, like `AnswerPromptTests`, and for
/// the same reason: "Return was pressed" passes against a driver that pressed it blind. Every
/// refusal below is an empty event list, or arrows with no Return after them.
@MainActor
final class ScreenPromptStoreTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 2_000_000)
    private var aborts: [AnswerAbort] = []

    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    private func captured(_ name: String) throws -> String {
        try TimelineFixtureTests.text(name, in: "Claude")
    }

    /// A claude tab the transcript derivation can name nothing for — `prompt_changed` on every
    /// tick, which is what `/login`'s menu looks like to it — with a screen the test controls.
    private func makeStore(
        agent: AgentID = .claude,
        probe: @escaping (UUID) -> Result<String, TimelineErrorCode>? = { _ in .failure("prompt_changed") }
    ) -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: nil, persistence: nil)
        store.now = { [weak self] in self?.clock ?? Date() }
        store.openPromptProbe = probe
        store.answerAbortSink = { [weak self] in self?.aborts.append($0) }
        store.promptLifecycleSink = { _ in }
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"), agent: agent)
        return (store, spy, session.id)
    }

    private func tick(_ store: SessionStore, _ id: UUID) {
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
    }

    /// The store, already past the debounce with `screen` up — the state every answer test starts
    /// from — and the call id it offered.
    private func offered(
        _ screen: String
    ) throws -> (SessionStore, SpyInjector, UUID, String) {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = screen
        tick(store, id)
        advance(5)
        tick(store, id)
        let call = try XCTUnwrap(store.openPromptCalls[id], "the screen must have been offered")
        spy.events.removeAll()
        return (store, spy, id, call)
    }

    // MARK: - Folder trust

    private let probeFolder = "/private/tmp/dialogcap/work/trust-310"

    /// A store with claude accounts at `homes`, for the automatic answer, which reads them.
    private func makeStore(homes: [URL]) -> (SessionStore, SpyInjector, UUID) {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.accounts = homes.enumerated().map {
            AgentAccount(agent: .claude, displayName: "account \($0.offset)", home: $0.element)
        }
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        store.now = { [weak self] in self?.clock ?? Date() }
        store.openPromptProbe = { _ in .failure("prompt_changed") }
        store.answerAbortSink = { [weak self] in self?.aborts.append($0) }
        store.promptLifecycleSink = { _ in }
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"), agent: .claude)
        return (store, spy, session.id)
    }

    /// A claude home whose config trusts exactly `folders`.
    private func home(trusting folders: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let projects = Dictionary(uniqueKeysWithValues: folders.map { ($0, ["hasTrustDialogAccepted": true]) })
        try JSONSerialization.data(withJSONObject: ["projects": projects])
            .write(to: home.appendingPathComponent(".claude.json"))
        return home
    }

    /// claude writes no status file and fires no hook until its trust screen is answered, so the
    /// registry has no row for the tab. The screen alone must make it `waiting` and offer the
    /// card — at once, with no debounce, since there is no transcript to race.
    func testATabOnTheTrustScreenWithNoRegistryRowIsWaitingWithACard() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        store.applyRegistry([:])

        XCTAssertEqual(store.status(for: id)?.activity, .waiting)
        let call = try XCTUnwrap(store.openPromptCalls[id])
        XCTAssertTrue(ScreenPromptID.isMenu(call), call)
        guard case .question(_, let questions)? = store.openPromptOffers[id] else {
            return XCTFail("expected a question offer")
        }
        XCTAssertEqual(questions[0].options.map(\.label), ["No, exit", "Yes, I trust this folder"])
    }

    func testATabWithNoRowAndAnOrdinaryScreenStaysWithoutAStatus() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("login-method.captured")
        store.applyRegistry([:])
        XCTAssertNil(store.status(for: id))
    }

    /// The phone's "Yes" is one row down on a current claude: one arrow, a re-read that finds the
    /// cursor on it, then Return.
    func testAnsweringYesMovesOntoTheTrustRowAndPressesIt() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        store.applyRegistry([:])
        let call = try XCTUnwrap(store.openPromptCalls[id])
        spy.events.removeAll()
        let landed = try captured("workspace-trust-310-yes-focused.captured")
        store.injectionSettle = { spy.viewportOverride = landed; $0() }

        let outcome = store.answerScreenPrompt(
            call, with: .option(index: 1, label: "Yes, I trust this folder"), in: id, token: UUID()
        )
        XCTAssertEqual(outcome, .dispatched)
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    /// The arrow did not take — the screen still shows the cursor on `No, exit` — so no Return.
    func testAYesWhoseArrowDidNotLandIsNeverPressed() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        store.applyRegistry([:])
        let call = try XCTUnwrap(store.openPromptCalls[id])
        spy.events.removeAll()

        _ = store.answerScreenPrompt(
            call, with: .option(index: 1, label: "Yes, I trust this folder"), in: id, token: UUID()
        )
        XCTAssertEqual(spy.events, [.arrow(1)])
    }

    /// A label that disagrees with the screen's row is refused before any key.
    func testALabelThatIsNotTheRowsIsRefusedBeforeAnyKey() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        store.applyRegistry([:])
        let call = try XCTUnwrap(store.openPromptCalls[id])
        spy.events.removeAll()

        _ = store.answerScreenPrompt(
            call, with: .option(index: 0, label: "Yes, I trust this folder"), in: id, token: UUID()
        )
        XCTAssertEqual(spy.events, [])
    }

    /// Another account trusts exactly this folder: once the screen has been up long enough to
    /// take keys, it is answered yes.
    func testAFolderTrustedExactlyElsewhereIsAnsweredYesAfterTheSettle() throws {
        let (store, spy, _) = makeStore(homes: [try home(trusting: []), try home(trusting: [probeFolder])])
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        let landed = try captured("workspace-trust-310-yes-focused.captured")
        store.injectionSettle = { spy.viewportOverride = landed; $0() }

        store.applyRegistry([:])
        XCTAssertEqual(spy.events, [], "not the instant the rows are drawn — the press would be dropped")
        advance(SessionStore.trustScreenSettle)
        store.applyRegistry([:])
        XCTAssertEqual(spy.events, [.arrow(1), .ret])

        advance(1)
        store.applyRegistry([:])
        XCTAssertEqual(spy.events, [.arrow(1), .ret], "nothing more inside the retry interval")
    }

    /// **What the first release did live**: the arrow had not shown on the re-read, so no Return —
    /// and the screen sat there. It had landed late; the next attempt reads the cursor already on
    /// `Yes`, sends no arrow, and presses.
    func testAnArrowThatLandsLateIsFinishedByTheNextAttemptWithoutAnotherArrow() throws {
        let (store, spy, _) = makeStore(homes: [try home(trusting: [probeFolder])])
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        store.applyRegistry([:])
        advance(SessionStore.trustScreenSettle)
        store.applyRegistry([:])
        XCTAssertEqual(spy.events, [.arrow(1)], "the landing check refuses the Return")

        spy.viewportOverride = try captured("workspace-trust-310-yes-focused.captured")
        advance(SessionStore.trustScreenRetryInterval)
        store.applyRegistry([:])
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    /// An arrow that never lands is tried a bounded number of times, then left for a person.
    func testAScreenThatNeverTakesTheArrowIsLeftAfterTheLastAttempt() throws {
        let (store, spy, _) = makeStore(homes: [try home(trusting: [probeFolder])])
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        store.applyRegistry([:])
        advance(SessionStore.trustScreenSettle)
        for _ in 0..<(SessionStore.trustScreenMaxAttempts + 2) {
            store.applyRegistry([:])
            advance(SessionStore.trustScreenRetryInterval)
        }
        XCTAssertEqual(spy.events, Array(repeating: .arrow(1), count: SessionStore.trustScreenMaxAttempts))
    }

    /// A trusted PARENT is a wider grant than the question asked, and carries nothing.
    func testAFolderWhoseParentIsTrustedElsewhereIsLeftForAPerson() throws {
        let parent = (probeFolder as NSString).deletingLastPathComponent
        let (store, spy, _) = makeStore(homes: [try home(trusting: [parent])])
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        store.applyRegistry([:])
        advance(SessionStore.trustScreenSettle)
        store.applyRegistry([:])
        XCTAssertEqual(spy.events, [])
    }

    func testAFolderNoAccountTrustsIsLeftForAPerson() throws {
        let (store, spy, _) = makeStore(homes: [try home(trusting: ["/somewhere/else"])])
        spy.viewportOverride = try captured("workspace-trust-310.captured")
        store.applyRegistry([:])
        advance(SessionStore.trustScreenSettle)
        store.applyRegistry([:])
        XCTAssertEqual(spy.events, [])
    }

    // MARK: - When it is offered

    /// **The ordinary one-second status/transcript race must never reach the screen.** For the
    /// first seconds of any episode the transcript is simply behind the status file, and a card
    /// offered then would be for a dialog the very next tick names properly.
    func testNothingIsReadOrOfferedBeforeTheDebounce() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("login-method.captured")
        tick(store, id)
        advance(4)
        tick(store, id)

        XCTAssertNil(store.openPromptCalls[id])
        XCTAssertNil(store.openPromptOffers[id])
        XCTAssertFalse(store.status(for: id)?.answerless ?? true)
    }

    func testPastTheDebounceTheLoginMenuIsOfferedAsAQuestionUnderAScreenIdentity() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("login-method.captured")
        tick(store, id)
        advance(5)
        tick(store, id)

        let call = try XCTUnwrap(store.openPromptCalls[id])
        XCTAssertTrue(ScreenPromptID.isMenu(call), call)
        guard case .question(let offeredCall, let questions)? = store.openPromptOffers[id] else {
            return XCTFail("expected a question offer, got \(String(describing: store.openPromptOffers[id]))")
        }
        XCTAssertEqual(offeredCall, call, "the id and the words name one dialog")
        XCTAssertEqual(questions[0].question, "Select login method:")
        XCTAssertEqual(questions[0].options.count, 3)
        XCTAssertFalse(store.status(for: id)?.answerless ?? true,
                       "there is a card now, so this is not the 'nothing to answer' state")
    }

    /// **The episode must survive the offer.** The transcript probe fails on every tick for as
    /// long as the menu is up; an offer that cleared the episode would restart the 5 s debounce
    /// each time and the card would blink out and back.
    func testTheOfferIsHeldAcrossTicksAndTheEpisodeIsNotRestarted() throws {
        let (store, _, id, call) = try offered(try captured("login-method.captured"))
        let began = try XCTUnwrap(store.stuckEpisodeForTesting(id)).began

        for _ in 0..<4 {
            advance(0.5)
            tick(store, id)
            XCTAssertEqual(store.openPromptCalls[id], call)
        }
        XCTAssertEqual(try XCTUnwrap(store.stuckEpisodeForTesting(id)).began, began)
    }

    /// A different menu while the session stays `waiting` is a different id: a wire change.
    func testAMenuReplacedByAnotherIsADifferentCall() throws {
        let (store, spy, id, call) = try offered(try captured("login-method.captured"))
        spy.viewportOverride = " Pick a model:\n\n ❯ 1. Opus\n   2. Sonnet"
        advance(0.5)
        tick(store, id)

        let next = try XCTUnwrap(store.openPromptCalls[id])
        XCTAssertNotEqual(next, call)
        XCTAssertTrue(ScreenPromptID.isMenu(next))
    }

    /// The menu answered at the keyboard: nothing on screen is a dialog any more, the offer goes,
    /// and the tab falls back to exactly what it was before this feature.
    func testWhenTheScreenStopsBeingADialogTheOfferIsWithdrawn() throws {
        let (store, spy, id, _) = try offered(try captured("login-method.captured"))
        spy.viewportOverride = "─────\n❯ \n─────"
        advance(0.5)
        tick(store, id)

        XCTAssertNil(store.openPromptCalls[id])
        XCTAssertNil(store.openPromptOffers[id])
        XCTAssertTrue(store.status(for: id)?.answerless ?? false, "back to the unchanged 'waiting' behaviour")
    }

    /// Out of scope, and pinned: the unnumbered theme picker produces no card at all.
    func testTheThemePickerIsNeverOffered() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("login-theme-picker.captured")
        tick(store, id)
        advance(5)
        tick(store, id)
        advance(60)
        tick(store, id)

        XCTAssertNil(store.openPromptCalls[id])
        XCTAssertNil(store.openPromptOffers[id])
    }

    /// A dialog the transcript CAN name is that dialog's, whatever the screen shows.
    func testANameableTranscriptDialogIsNeverReplacedByTheScreen() throws {
        let (store, spy, id) = makeStore(probe: { _ in .success("toolu_A") })
        spy.viewportOverride = try captured("login-method.captured")
        tick(store, id)
        advance(30)
        tick(store, id)

        XCTAssertEqual(store.openPromptCalls[id], "toolu_A")
        XCTAssertNil(store.openPromptOffers[id])
    }

    func testThePasteCodeScreenIsOfferedAsASignIn() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try captured("login-paste-code.captured")
        tick(store, id)
        advance(5)
        tick(store, id)

        let call = try XCTUnwrap(store.openPromptCalls[id])
        XCTAssertTrue(ScreenPromptID.isSignIn(call))
        guard case .signIn(_, let url)? = store.openPromptOffers[id] else {
            return XCTFail("expected a sign-in offer")
        }
        XCTAssertTrue(url.hasPrefix("https://claude.com/cai/oauth/authorize?"))
    }

    /// **Claude only.** Another agent's screen is another grammar, and this reads claude's.
    func testAnotherAgentIsNeverOfferedAScreenDialog() throws {
        let (store, spy, id) = makeStore(agent: .grok)
        spy.viewportOverride = try captured("login-method.captured")
        tick(store, id)
        advance(30)
        tick(store, id)

        XCTAssertNil(store.openPromptCalls[id])
        XCTAssertNil(store.openPromptOffers[id])
    }

    // MARK: - Answering a menu

    func testCodexWaitsForDelayedCursorRepaintThenSubmitsWithoutMoreArrows() throws {
        let (store, spy, id) = makeStore(agent: .codex)
        let screen = "Would you like to run the following command?\nReason: Continue?\n$ git rebase master\n\n› 1. Yes\n  2. Remember\n\nPress enter to confirm or esc to cancel"
        spy.viewportOverride = screen
        tick(store, id)
        let call = try XCTUnwrap(CodexScreenPrompt.read(screen)?.callID)
        var settles = 0
        store.injectionSettle = { work in
            settles += 1
            if settles == 2 {
                spy.viewportOverride = screen.replacingOccurrences(of: "› 1. Yes\n  2. Remember", with: "  1. Yes\n› 2. Remember")
            }
            work()
        }
        spy.events.removeAll()
        XCTAssertEqual(store.answerScreenPrompt(call, with: .option(index: 1, label: "Remember"), in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
        XCTAssertTrue(aborts.isEmpty)
    }

    /// An offered menu on the spy's own modelled list, whose arrows really move the marker.
    private func offeredModelledMenu(
        labels: [String] = ["Pro", "Console", "3rd party"]
    ) throws -> (SessionStore, SpyInjector, UUID, String) {
        let (store, spy, id) = makeStore()
        spy.showOptions(labels, selected: 0)
        tick(store, id)
        advance(5)
        tick(store, id)
        let call = try XCTUnwrap(store.openPromptCalls[id], "the modelled list must read as a menu")
        spy.events.removeAll()
        return (store, spy, id, call)
    }

    func testTappingARowMovesTheCursorThenPressesReturn() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 2, label: "3rd party"), in: id, token: UUID()),
            .dispatched)
        XCTAssertEqual(spy.events, [.arrow(1), .arrow(1), .ret])
    }

    func testTheSameAnswerAsAOneQuestionSetIsDrivenIdentically() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        XCTAssertEqual(
            store.answerScreenPrompt(
                call, with: .answers([[AnswerSelection(index: 1, label: "Console")]]), in: id, token: UUID()),
            .dispatched)
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    func testTheFocusedRowIsAnsweredWithNoArrows() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        store.answerScreenPrompt(call, with: .option(index: 0, label: "Pro"), in: id, token: UUID())
        XCTAssertEqual(spy.events, [.ret])
    }

    /// **Identity changed: the screen is another menu, so nothing is pressed.** This is the whole
    /// reason the id is a digest of the words — a phone tapping a stale card never reaches a key.
    func testAnAnswerToAMenuThatHasBeenReplacedIsRefusedWithNothingPressed() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        spy.showOptions(["Opus", "Sonnet", "Haiku"], selected: 0)

        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 1, label: "Console"), in: id, token: UUID()),
            .promptChanged)
        XCTAssertEqual(SessionStore.AnswerDispatch.promptChanged.errorCode, "prompt_changed")
        XCTAssertEqual(spy.events, [])
        XCTAssertEqual(aborts.last?.check, .screenPromptChanged)
    }

    func testAnAnswerAfterTheMenuIsGoneIsRefusedWithNothingPressed() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        spy.viewportOverride = "─────\n❯ \n─────"

        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 1, label: "Console"), in: id, token: UUID()),
            .promptChanged)
        XCTAssertEqual(spy.events, [])
    }

    /// **The label disagrees: the phone is looking at something else.** The id matched (so this
    /// is the menu the Mac offered), but the words the client sent for that row are not the
    /// row's — refused before an arrow moves.
    func testALabelThatIsNotTheRowsOwnIsRefusedWithNothingPressed() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 1, label: "Absolutely"), in: id, token: UUID()),
            .unreadableScreen)
        XCTAssertEqual(spy.events, [])
        XCTAssertEqual(aborts.last?.check, .screenRowMismatch)
        XCTAssertNil(aborts.last?.expected, "labels never ride an AnswerAbort summary, which goes to os_log")
    }

    func testAnIndexOutsideTheRowsIsRefusedWithNothingPressed() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        for index in [-1, 3, 99] {
            XCTAssertEqual(
                store.answerScreenPrompt(call, with: .option(index: index, label: "Pro"), in: id, token: UUID()),
                .unreadableScreen, "\(index)")
        }
        XCTAssertEqual(spy.events, [])
    }

    /// A cursor that did not land on the row — a dropped keystroke, a late repaint — gets no
    /// Return. Moved is recoverable at the keyboard; a wrong Return is not.
    func testReturnIsNotPressedWhenTheCursorDidNotLand() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        spy.ignoreArrowsAfter = 1

        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 2, label: "3rd party"), in: id, token: UUID()),
            .dispatched, "dispatched; whether it landed is a later fact")
        XCTAssertEqual(spy.events, [.arrow(1), .arrow(1)])
        XCTAssertFalse(spy.events.contains(.ret))
        XCTAssertEqual(aborts.last?.check, .landingAfterMove)
    }

    /// The menu repaints into another while the arrows are in flight: the marker lands where it
    /// was sent and the row no longer says what was asked. No Return.
    func testReturnIsNotPressedWhenTheMenuChangesWhileTheCursorMoves() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        spy.relabelAfterArrows(["Pro", "Something else", "3rd party"])

        store.answerScreenPrompt(call, with: .option(index: 1, label: "Console"), in: id, token: UUID())
        XCTAssertEqual(spy.events, [.arrow(1)])
    }

    func testATypedAnswerToAMenuIsRefusedBecauseAMenuHasNoTypeSomethingRow() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        XCTAssertEqual(
            store.answerScreenPrompt(
                call, with: .answers([[.typed("hello", optionCount: 3)]]), in: id, token: UUID()),
            .unanswerable)
        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .answers([[], []]), in: id, token: UUID()),
            .unanswerable)
        XCTAssertEqual(spy.events, [])
    }

    func testAllowIsNeverAnAnswerToAScreenMenu() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        XCTAssertEqual(store.answerScreenPrompt(call, with: .allow, in: id, token: UUID()), .unanswerable)
        XCTAssertEqual(spy.events, [])
    }

    func testAReplayedTokenPressesNothingTwice() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        let token = UUID()
        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 1, label: "Console"), in: id, token: token),
            .dispatched)
        spy.events.removeAll()
        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 1, label: "Console"), in: id, token: token),
            .duplicate)
        XCTAssertEqual(spy.events, [])
    }

    func testAnAnswerToATabThatIsNoLongerWaitingIsRefused() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        store.applyRegistryForTesting([id: SessionStatus(activity: .busy)])
        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 1, label: "Console"), in: id, token: UUID()),
            .notWaiting)
        XCTAssertEqual(spy.events, [])
    }

    func testAnUnreadableScreenIsRefusedWithNothingPressed() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        spy.viewportIsReadable = false
        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 1, label: "Console"), in: id, token: UUID()),
            .unreadableScreen)
        XCTAssertEqual(spy.events, [])
    }

    func testAnotherAgentsTabIsRefusedBeforeTheScreenIsRead() throws {
        let (store, spy, id) = makeStore(agent: .grok)
        spy.showOptions(["Pro", "Console"], selected: 0)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        let call = ScreenPromptID.menu(prompt: "Do you want to proceed?", labels: ["Pro", "Console"])
        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 1, label: "Console"), in: id, token: UUID()),
            .unsupportedAgent)
        XCTAssertEqual(spy.events, [])
    }

    // MARK: - Cancelling

    /// "Escape/cancel should work as it does for questions": one Escape, here after the identity
    /// check — a stale Escape into a live turn would interrupt it.
    func testCancellingAMenuSendsOneEscape() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        XCTAssertEqual(store.answerScreenPrompt(call, with: .deny, in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.escape])
    }

    func testCancellingAMenuThatHasBeenReplacedSendsNothing() throws {
        let (store, spy, id, call) = try offeredModelledMenu()
        spy.showOptions(["Opus", "Sonnet"], selected: 0)
        XCTAssertEqual(store.answerScreenPrompt(call, with: .deny, in: id, token: UUID()), .promptChanged)
        XCTAssertEqual(spy.events, [])
    }

    // MARK: - Answering a sign-in

    func testTheCodeIsPastedThenReturnIsPressed() throws {
        let (store, spy, id, call) = try offered(try captured("login-paste-code.captured"))
        XCTAssertEqual(
            store.answerScreenPrompt(
                call, with: .answers([[.typed("abc123#def", optionCount: 0)]]), in: id, token: UUID()),
            .dispatched)
        XCTAssertEqual(spy.events, [.text("abc123#def"), .ret])
    }

    /// A code pasted from a page arrives with its trailing newline; that is not part of it.
    func testTheCodeIsTrimmedBeforeItIsPasted() throws {
        let (store, spy, id, call) = try offered(try captured("login-paste-code.captured"))
        store.answerScreenPrompt(
            call, with: .answers([[.typed("  abc123 \n", optionCount: 0)]]), in: id, token: UUID())
        XCTAssertEqual(spy.events, [.text("abc123"), .ret])
    }

    /// `AnswerPlan.acceptsTyped`'s rule: in claude's one-line field a newline is Return and an
    /// Escape ends the paste and cancels the dialog. Refused, with nothing pasted.
    func testACodeWithAControlCharacterIsRefusedWithNothingPasted() throws {
        let (store, spy, id, call) = try offered(try captured("login-paste-code.captured"))
        for text in ["abc\ndef", "abc\u{1b}def", "abc\rdef", "ab\u{0}c", "abc\tdef", "", "   ", "\n"] {
            XCTAssertEqual(
                store.answerScreenPrompt(
                    call, with: .answers([[.typed(text, optionCount: 0)]]), in: id, token: UUID()),
                .unanswerable, text.debugDescription)
        }
        XCTAssertEqual(spy.events, [])
        XCTAssertEqual(aborts.last?.check, .signInTextRefused)
        XCTAssertNil(aborts.last?.viewport, "a sign-in's whole screen is its URL and state: never filed")
    }

    func testAnAbsurdlyLongCodeIsRefused() throws {
        let (store, spy, id, call) = try offered(try captured("login-paste-code.captured"))
        XCTAssertEqual(
            store.answerScreenPrompt(
                call, with: .answers([[.typed(String(repeating: "a", count: 5000), optionCount: 0)]]),
                in: id, token: UUID()),
            .unanswerable)
        XCTAssertEqual(spy.events, [])
    }

    func testASignInTakesOnlyOneTypedSelection() throws {
        let (store, spy, id, call) = try offered(try captured("login-paste-code.captured"))
        let shapes: [PromptAnswer] = [
            .option(index: 0, label: "x"), .allow,
            .answers([[AnswerSelection(index: 0, label: "x")]]),
            .answers([[.typed("a", optionCount: 0), .typed("b", optionCount: 0)]]),
            .answers([[.typed("a", optionCount: 0)], [.typed("b", optionCount: 0)]]),
        ]
        for shape in shapes {
            XCTAssertEqual(store.answerScreenPrompt(call, with: shape, in: id, token: UUID()),
                           .unanswerable, "\(shape)")
        }
        XCTAssertEqual(spy.events, [])
    }

    /// Identity changed: a second login attempt put another sign-in up, so a code the reader
    /// copied for the first is not pasted into the second.
    func testACodeForAnotherLoginAttemptIsNotPasted() throws {
        let screen = try captured("login-paste-code.captured")
        let (store, spy, id, call) = try offered(screen)
        spy.viewportOverride = screen.replacingOccurrences(
            of: "FAKE-state-PLACEHOLDER-0", with: "FAKE-state-PLACEHOLDER-1")

        XCTAssertEqual(
            store.answerScreenPrompt(
                call, with: .answers([[.typed("abc123", optionCount: 0)]]), in: id, token: UUID()),
            .promptChanged)
        XCTAssertEqual(spy.events, [])
        XCTAssertNil(aborts.last?.viewport)
    }

    /// The reader finishes the login in the Mac's own browser while the card is up, and claude
    /// moves on. Checked once more after the paste lands, because a Return into whatever claude
    /// drew next submits whatever that screen has focused.
    func testReturnIsNotPressedIfTheSignInLeftTheScreenDuringThePaste() throws {
        let screen = try captured("login-paste-code.captured")
        let (store, spy, id, call) = try offered(screen)
        store.injectionSettle = { work in
            spy.viewportOverride = "─────\n❯ \n─────"
            work()
        }

        XCTAssertEqual(
            store.answerScreenPrompt(
                call, with: .answers([[.typed("abc123", optionCount: 0)]]), in: id, token: UUID()),
            .dispatched)
        XCTAssertEqual(spy.events, [.text("abc123")], "pasted, and then no Return")
        XCTAssertEqual(aborts.last?.check, .screenPromptChanged)
        XCTAssertNil(aborts.last?.viewport)
    }

    func testCancellingASignInSendsOneEscape() throws {
        let (store, spy, id, call) = try offered(try captured("login-paste-code.captured"))
        XCTAssertEqual(store.answerScreenPrompt(call, with: .deny, in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.escape])
    }

    /// A menu's call id naming a sign-in screen (the menu was answered, claude moved on to the
    /// sign-in) is the stale tap it looks like, and must not paste anything either.
    func testAMenuTapThatLandsOnTheSignInScreenIsRefused() throws {
        let (store, spy, id, call) = try offered(try captured("login-method.captured"))
        spy.viewportOverride = try captured("login-paste-code.captured")

        XCTAssertEqual(
            store.answerScreenPrompt(call, with: .option(index: 0, label: "x"), in: id, token: UUID()),
            .promptChanged)
        XCTAssertEqual(spy.events, [])
        XCTAssertNil(aborts.last?.viewport, "the screen under a stale menu tap may be the sign-in's")
    }
}
