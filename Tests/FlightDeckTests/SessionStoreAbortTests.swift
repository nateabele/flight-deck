import XCTest
@testable import FleetKit
@testable import FlightDeck

/// `SessionStore.abortPrompt` — Escape sent at a dialog nothing on this build can name.
///
/// **The guards are `answerPrompt`'s own, in the same order, minus the call comparison it has
/// nothing to compare.** This file exists to prove the order rather than assume it: every
/// fixturable guard below is reached by exactly one test, and `testDuplicateOutranksNotWaiting`
/// pins the one place the order is not obvious from reading top to bottom. The one guard this
/// file cannot fixture — `.unsupportedAgent` — is recorded, not silently skipped: see the note
/// above `testAnUnknownSessionIsRefused`.
@MainActor
final class SessionStoreAbortTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
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

    /// Same shape as `AnswerPromptTests.makeStore`: a claude tab whose injection settles
    /// synchronously, so a test reads as straight-line code.
    private func makeStore(activity: SessionActivity) -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        store.answerAbortSink = { _ in }
        store.promptLifecycleSink = { _ in }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id)
    }

    // MARK: The gates, one per test
    //
    // No test here reaches `.unsupportedAgent`, the second gate in `dispatchAbort`, and none
    // can: `AgentID` has exactly two cases and both now carry a real `dialogDriver`, the same
    // gap `AnswerPromptTests.testAnIdleCodexTabIsRefusedByTheStatusGateLikeAnyOther`'s comment
    // already records for `answerPrompt`'s identical guard. The order — agent capability before
    // activity — is pinned in `dispatchAbort`'s own comment instead, until a third agent exists
    // to fixture it.

    func testAnUnknownSessionIsRefused() {
        let (store, spy, _) = makeStore(activity: .waiting)
        XCTAssertEqual(store.abortPrompt(in: UUID(), token: UUID()), .unknownSession)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **`notWaiting` is load-bearing, not a formality.** A stray Escape into a live TUI is not
    /// free — it can dismiss a menu, back out of an editor, or land on the wrong pane — so an
    /// idle or busy session must refuse exactly as hard as `answerPrompt` does.
    func testANonWaitingSessionIsRefused() {
        for activity in [SessionActivity.idle, .busy] {
            let (store, spy, id) = makeStore(activity: activity)
            XCTAssertEqual(
                store.abortPrompt(in: id, token: UUID()), .notWaiting,
                "a stray Escape into a live TUI is not free"
            )
            XCTAssertTrue(spy.events.isEmpty, "\(activity) must send nothing, not even Escape")
        }
    }

    /// A closed tab has no surface, so there is nothing to send a key event to.
    func testATabWithNoSurfaceIsRefused() {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.injectionSettle = { $0() }
        store.promptLifecycleSink = { _ in }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, .waiting, cwd: tmp.path)])
        XCTAssertNil(store.viewport(of: session.id), "no surface, nothing to read")
        XCTAssertEqual(
            store.abortPrompt(in: session.id, token: UUID()), .unreadableScreen
        )
    }

    /// The same `injecting` set a rename or a queued phone prompt holds, so an abort cannot
    /// interleave with either.
    func testATabAlreadyInjectingIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        store.holdInjectionForTesting(id)
        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .unreadableScreen)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **The property, asserted rather than described.** Abort reads nothing off the screen —
    /// the spy's viewport is deliberately unreadable — so it works on a screen this build
    /// cannot parse at all, which is exactly the state a blocked dialog is in.
    func testDispatchedAbortSendsOneEscapeAndReadsNoViewport() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.viewportIsReadable = false
        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.escape], "abort sends one key and reads no viewport")
    }

    // MARK: The Mac's own verdict on the dialog
    //
    // `makeStore` leaves `openPromptProbe` nil — a bare store has no dialog derivation at all —
    // which reads as `.unavailable` and refuses nothing, so every test above exercises the same
    // guards it always did. These three install one.

    /// **A dialog this Mac can name is not this command's business.** Everything the phone
    /// weighs before offering Abort is phone-side; an unparseable body or a page that never
    /// landed leaves it looking identical over a call `PromptService` resolves perfectly well,
    /// and Escape there blind-denies a real tool call the reader was never shown. A distinct
    /// code, because none of the other refusals is true of this tab.
    func testAbortIsRefusedWhenThisMacCanNameTheDialog() {
        let (store, spy, id) = makeStore(activity: .waiting)
        store.openPromptProbe = { _ in nil }

        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .promptNameable)
        XCTAssertTrue(spy.events.isEmpty, "no key may be typed at a dialog that has an answer")
    }

    /// The refusal must not burn the token: a phone whose first tap was refused because the Mac
    /// could momentarily name the dialog has to be able to tap again once it cannot.
    func testARefusedNameableAbortLeavesTheTokenUnspent() {
        let (store, spy, id) = makeStore(activity: .waiting)
        let token = UUID()
        store.openPromptProbe = { _ in nil }
        XCTAssertEqual(store.abortPrompt(in: id, token: token), .promptNameable)

        store.openPromptProbe = { _ in "prompt_changed" }
        XCTAssertEqual(
            store.abortPrompt(in: id, token: token), .dispatched,
            "the token was never remembered, so the retry is a first attempt, not a replay"
        )
        XCTAssertEqual(spy.events, [.escape])
    }

    /// **The order, pinned.** The status gate outranks this one, so a session that has left
    /// `waiting` is told `not_waiting` — the truer sentence, and the one the phone already
    /// renders — rather than being told something about a dialog that is no longer up.
    func testNotWaitingOutranksPromptNameable() {
        let (store, spy, id) = makeStore(activity: .idle)
        store.openPromptProbe = { _ in nil }

        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .notWaiting)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The guard's own premise: a probe that cannot name the dialog is the state this whole
    /// feature exists for, and it must still dispatch.
    func testAnUnnameableDialogStillDispatches() {
        let (store, spy, id) = makeStore(activity: .waiting)
        store.openPromptProbe = { _ in "prompt_changed" }

        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.escape])
    }

    // MARK: Token idempotency

    func testTheSameTokenTwiceAbortsOnce() {
        let (store, spy, id) = makeStore(activity: .waiting)
        let token = UUID()
        XCTAssertEqual(store.abortPrompt(in: id, token: token), .dispatched)
        let before = spy.events.count
        XCTAssertEqual(store.abortPrompt(in: id, token: token), .duplicate)
        XCTAssertEqual(spy.events.count, before, "a repeat types nothing")
    }

    func testADifferentTokenAbortsAgain() {
        let (store, spy, id) = makeStore(activity: .waiting)
        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .dispatched)
        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.escape, .escape])
    }

    /// **The order pinned, not merely stated.** Once a token has been used, the duplicate
    /// check is reached — and short-circuits — before the activity gate is, so a token replayed
    /// after the session left `waiting` still reads `.duplicate`, not `.notWaiting`. A store
    /// that checked activity first would report the wrong reason for refusing a retried tap.
    func testDuplicateOutranksNotWaiting() {
        let (store, spy, id) = makeStore(activity: .waiting)
        let token = UUID()
        XCTAssertEqual(store.abortPrompt(in: id, token: token), .dispatched)

        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        XCTAssertEqual(
            store.abortPrompt(in: id, token: token), .duplicate,
            "a remembered token is refused as a duplicate even once the session is idle"
        )
        XCTAssertEqual(spy.events, [.escape], "the replay must not send a second Escape")
    }

    /// The dedupe list is bounded, exactly as `answerPrompt`'s is, so a tab left open for a
    /// week does not accumulate one entry per tap.
    func testTheOldestRememberedTokenIsEvicted() {
        let (store, _, id) = makeStore(activity: .waiting)
        let tokens = (0...SessionStore.maxRememberedPromptTokens).map { _ in UUID() }
        for token in tokens {
            XCTAssertEqual(store.abortPrompt(in: id, token: token), .dispatched)
        }
        XCTAssertEqual(
            store.abortPrompt(in: id, token: tokens[1]), .duplicate,
            "the second-oldest token is still inside the window"
        )
        XCTAssertEqual(
            store.abortPrompt(in: id, token: tokens[0]), .dispatched,
            "the oldest has fallen out of it"
        )
    }
}
