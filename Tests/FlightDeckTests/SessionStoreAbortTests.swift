import XCTest
@testable import FleetKit
@testable import FlightDeck

/// `SessionStore.abortPrompt` — Escape sent at a dialog nothing on this build can name.
///
/// **The guards are `answerPrompt`'s own, in the same order, minus the call comparison it has
/// nothing to compare.** This file exists to prove the order rather than assume it: each test
/// below reaches exactly one guard by construction, and `testDuplicateOutranksNotWaiting` pins
/// the one place the order is not obvious from reading top to bottom.
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
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id)
    }

    // MARK: The gates, one per test

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
