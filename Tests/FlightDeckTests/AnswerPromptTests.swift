import XCTest
@testable import FleetKit
@testable import FlightDeck

/// Answering a dialog by driving the terminal.
///
/// **The ORDER of the events is the contract**, exactly as it is for `inject`: arrows first,
/// screen re-read, Return only if the marker landed where it was sent. A test asserting only
/// "Return was pressed" would pass against a driver that pressed it blind, which is the failure
/// mode with someone's `rm -rf` on the other side.
@MainActor
final class AnswerPromptTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Answers `thread/name/set` so a codex tab can be created at all. Lifted from
    /// `PhonePromptDispatchTests`, which needs a real codex tab for the same reason.
    private final class ScriptedCodexTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    /// Thrown after an `XCTFail`, so a helper that cannot build its fixture stops the test it
    /// was building it for rather than returning a store nothing was set up on.
    private struct CodexTabUnavailable: Error {}

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

    /// A claude tab whose injection settles synchronously, so the tests read as straight-line
    /// code. Same shape as `PhonePromptDispatchTests.makeStore`.
    private func makeStore(activity: SessionActivity) -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id)
    }

    /// A codex tab, given a status directly because no claude registry describes one.
    private func makeCodexStore(activity: SessionActivity) async throws
        -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedCodexTransport())),
            for: .codex, account: nil
        )
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        guard case .success(let id) = await store.createSession(agent: .codex, in: tmp.path) else {
            XCTFail("codex tab creation must succeed against a scripted transport")
            throw CodexTabUnavailable()
        }
        store.applyRegistryForTesting([id: SessionStatus(activity: activity)])
        spy.events.removeAll()
        return (store, spy, id)
    }

    private func question(labels: [String], unanswerable: String? = nil) -> OpenPrompt {
        .question(callID: "toolu_A", PromptQuestion(
            header: "Pick", question: "Which?",
            options: labels.map { .init(label: $0) }, unanswerable: unanswerable
        ))
    }

    private var permission: OpenPrompt {
        .permission(callID: "toolu_B", tool: "Bash", summary: "rm -rf build")
    }

    // MARK: option — an AskUserQuestion

    func testChoosingTheRowBelowSendsOneArrowThenReturn() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No", "Maybe"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    func testChoosingTheRowAlreadySelectedSendsReturnAndNoArrows() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(question(labels: ["Yes", "No"]),
                           with: .option(index: 0, label: "Yes"), in: id, token: UUID())
        XCTAssertEqual(spy.events, [.ret])
    }

    func testChoosingARowAboveSendsUpArrows() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No", "Maybe"], selected: 2)
        store.answerPrompt(question(labels: ["Yes", "No", "Maybe"]),
                           with: .option(index: 0, label: "Yes"), in: id, token: UUID())
        XCTAssertEqual(spy.events, [.arrow(-1), .arrow(-1), .ret])
    }

    /// **The test this whole funnel exists for.** The fake stops moving after one row —
    /// modelling a TUI that dropped a keystroke, repainted late, or was never the list we
    /// thought — and the driver must send nothing further. A moved cursor is recoverable by
    /// the person at the keyboard; a Return on the wrong row is not.
    func testReturnIsNotPressedWhenTheMarkerDidNotLandOnTheChosenRow() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.ignoreArrowsAfter = 1
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No", "Maybe"]),
                               with: .option(index: 2, label: "Maybe"), in: id, token: UUID()),
            .dispatched, "dispatched; whether it landed is a later fact"
        )
        XCTAssertFalse(spy.events.contains(.ret), "no Return on an unconfirmed selection")
    }

    /// **The second half of the interlock, isolated.** The marker lands on the right row and
    /// that row says something else — a list whose order the Mac's copy no longer describes.
    /// Index alone would confirm here; the label is what refuses.
    func testReturnIsNotPressedWhenTheChosenRowDoesNotReadAsItsLabel() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.relabelAfterArrows(["Yes", "Something else entirely", "Maybe"])
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No", "Maybe"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(1)], "moved, then refused to press Return")
    }

    /// The label is a cross-check on the Mac's own copy, not an instruction. A client naming
    /// words the Mac never drew is a reader looking at something else.
    func testAnOptionWhoseLabelDisagreesWithTheMacsCopyIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 1, label: "Absolutely"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnIndexOutsideTheOptionsIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 7, label: "Yes"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnUnanswerableQuestionIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["a", "b"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(
                question(labels: ["a", "b"], unanswerable: PromptQuestion.multiSelectReason),
                with: .option(index: 0, label: "a"), in: id, token: UUID()
            ),
            .unanswerable
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// A screen showing a different dialog than the one derived. Nothing sent — the second
    /// half of the racing guard, below `PromptService`'s re-derivation. This is what makes the
    /// pre-flight check load-bearing: without it the driver would count arrows across a list
    /// it has never confirmed it is looking at, and only the re-read would catch it — after
    /// two keystrokes had already moved someone else's cursor.
    func testADialogThatIsNoLongerOnScreenIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Something else entirely", "And another"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The same state on the option path: readable screen, no list. Refused before an arrow
    /// is sent, because a relative move needs a starting row and there is none.
    func testAnOptionOnAScreenWithNoDialogIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **The rows claude appends at display time.** `question-single`'s three transcript
    /// options are five rows on screen — `Type something.` and `Chat about this` land below
    /// them — and the cursor can sit on one. The Mac has no label for that row, so there is
    /// nothing to confirm against and the answer is refused rather than counted from.
    func testACursorOnARowTheMacHasNoLabelForIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Rust", "Go", "Swift", "Type something.", "Chat about this"],
                        selected: 3)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Rust", "Go", "Swift"]),
                               with: .option(index: 0, label: "Rust"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// An intent that does not name the dialog that is up. `option` indexes an
    /// `AskUserQuestion`'s own options; a permission dialog has none this build can read, so
    /// there is no list for the index to mean anything in.
    func testAnOptionAgainstAPermissionDialogIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(permission, with: .option(index: 1, label: "No"),
                               in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    // MARK: deny — one Escape, no read

    /// **The property, asserted rather than described.** A denial reads nothing off the screen,
    /// so it works on a screen that cannot be read at all — which is exactly the state a person
    /// is in when they want to refuse something and the terminal is mid-repaint.
    func testDenyIsOneEscapeAndReadsNothing() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.viewportIsReadable = false
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.escape])
    }

    func testDenyWorksForAQuestionToo() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(question(labels: ["Yes", "No"]), with: .deny, in: id, token: UUID())
        XCTAssertEqual(spy.events, [.escape])
    }

    // MARK: allow — the first row

    func testAllowMovesToTheFirstRowAndReturns() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "Yes, and don't ask again", "No"], selected: 2)
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(-1), .arrow(-1), .ret])
    }

    /// **The security property, as a test.** There is no answer that reaches row 1 — the
    /// "don't ask again" row — and this asserts it from the outside: `.allow` on a three-row
    /// dialog leaves the marker at row 0, never row 1.
    func testNoAnswerCanReachTheDontAskAgainRow() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "Yes, and don't ask again", "No"], selected: 0)
        store.answerPrompt(permission, with: .allow, in: id, token: UUID())
        XCTAssertEqual(spy.selected, 0)
        XCTAssertEqual(spy.events, [.ret])
    }

    /// **The weaker half of the interlock, and the strongest test available for it.** There is
    /// no label to confirm a permission row against, so all `.allow` can require after moving
    /// is that the marker is on row 0. This is the case that says so: a TUI that ignored the
    /// arrows leaves the marker at row 2 and no Return is pressed.
    func testAllowPressesNoReturnWhenTheMarkerDidNotReachTheFirstRow() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "Yes, and don't ask again", "No"], selected: 2)
        spy.ignoreArrowsAfter = 0
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(-1), .arrow(-1)])
        XCTAssertEqual(spy.selected, 2, "the fixture is only meaningful if nothing moved")
    }

    /// A screen that reads perfectly well and has no dialog on it — the tab was answered at
    /// the keyboard a second before the tap arrived, leaving scrollback and an input bar.
    /// **This is the whole of `.allow`'s interlock**, so it is the case that has to refuse:
    /// there is no label to fall back on and nothing else to check.
    func testAllowOnAScreenWithNoDialogIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        XCTAssertNotNil(store.viewport(of: id), "the input bar is readable; there is just no list")
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAllowOnAScreenWithNoReadableDialogIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.viewportIsReadable = false
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The same mismatch as `testAnOptionAgainstAPermissionDialogIsRefused`, the other way
    /// round. `allow` means "the permission dialog's first row"; against a question, row 0 is
    /// whatever the first option happens to say, which is a decision nobody made.
    func testAllowAgainstAQuestionIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 1)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]), with: .allow,
                               in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    // MARK: The gates

    /// **`inject`'s gate, inverted, and the inversion is the point.** An idle session has no
    /// dialog up, and a Return there submits whatever is in the input bar.
    func testANonWaitingSessionIsRefused() {
        for activity in [SessionActivity.idle, .busy, .shell] {
            let (store, spy, id) = makeStore(activity: activity)
            spy.showOptions(["Yes"], selected: 0)
            XCTAssertEqual(
                store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .notWaiting
            )
            XCTAssertTrue(spy.events.isEmpty, "\(activity) must send nothing, not even Escape")
        }
    }

    /// **The order of the two guards, and an IDLE codex tab is the only fixture that pins
    /// it.** Agent first answers `unsupportedAgent` — never on this tab. Status first would
    /// answer `notWaiting` — not right now — inviting a retry that can never succeed. A
    /// *waiting* codex tab cannot tell the two apart, because it clears the status gate either
    /// way; that fixture proves something else, below.
    func testACodexTabIsRefusedBeforeItsStatusIsConsulted() async throws {
        let (store, spy, id) = try await makeCodexStore(activity: .idle)
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .unsupportedAgent
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// A codex tab that is ALSO waiting — the fixture where the Escape is reachable, so the
    /// agent guard is the only thing standing between a tap and a keystroke into a
    /// `codex resume` TUI. The two codex tests are not redundant: that one proves the order,
    /// this one proves the guard prevents the send. Same pairing as
    /// `PhonePromptDispatchTests`'s two.
    func testAWaitingCodexTabIsRefusedRatherThanDriven() async throws {
        let (store, spy, id) = try await makeCodexStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(store.status(for: id)?.activity, .waiting,
                       "the fixture is only meaningful if the status guard would have passed")
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .unsupportedAgent
        )
        XCTAssertTrue(spy.events.isEmpty,
                      "codex has no dialog this build has ever read, and a stray Escape into a "
                      + "live TUI is not free")
    }

    func testAnUnknownTabIsRefused() {
        let (store, spy, _) = makeStore(activity: .waiting)
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: UUID(), token: UUID()),
            .unknownSession
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The same token twice, with the screen reset between, so a store that forgot the token
    /// would send a second Escape.
    func testTheSameTokenTwiceAnswersOnce() {
        let (store, spy, id) = makeStore(activity: .waiting)
        let token = UUID()
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: token), .dispatched
        )
        let before = spy.events.count
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: token), .duplicate
        )
        XCTAssertEqual(spy.events.count, before, "a repeat types nothing")
    }

    /// The dedupe covers the driven paths too, not only the one-key Escape. A retry after a
    /// dropped `ack` must not send a second run of arrows into a list the first run has
    /// already moved — which would land two rows from where either tap meant.
    func testTheSameTokenTwiceOnAnOptionAnswersOnce() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        let token = UUID()
        let answer = PromptAnswer.option(index: 1, label: "No")
        store.answerPrompt(question(labels: ["Yes", "No"]), with: answer, in: id, token: token)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]), with: answer, in: id,
                               token: token),
            .duplicate
        )
        XCTAssertEqual(spy.events, [.arrow(1), .ret], "the second tap moved nothing")
    }

    /// Two different taps are two answers. The dedupe is per token, so a list that swallowed
    /// the second would lose a real one.
    func testADifferentTokenAnswersAgain() {
        let (store, spy, id) = makeStore(activity: .waiting)
        store.answerPrompt(permission, with: .deny, in: id, token: UUID())
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.escape, .escape])
    }

    /// The dedupe list is bounded, exactly as `acceptedPromptTokens` is, so a tab left open
    /// for a week does not accumulate one entry per tap. The bound is what this asserts: past
    /// it the oldest token is forgotten and answers again rather than being swallowed.
    func testTheOldestRememberedTokenIsEvicted() {
        let (store, _, id) = makeStore(activity: .waiting)
        let tokens = (0...SessionStore.maxRememberedPromptTokens).map { _ in UUID() }
        for token in tokens {
            XCTAssertEqual(
                store.answerPrompt(permission, with: .deny, in: id, token: token), .dispatched
            )
        }
        // The younger one first: a `duplicate` files nothing, so it cannot move the window it
        // is being read through, where the `dispatched` below evicts as it goes.
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: tokens[1]), .duplicate,
            "the second-oldest token is still inside the window"
        )
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: tokens[0]), .dispatched,
            "the oldest has fallen out of it"
        )
    }

    /// A closed tab has no surface, so there is nothing to send a key event to. Refused rather
    /// than dispatched into nothing.
    func testATabWithNoSurfaceIsRefused() {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, .waiting, cwd: tmp.path)])
        XCTAssertNil(store.viewport(of: session.id), "no surface, nothing to read")
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: session.id, token: UUID()),
            .unreadableScreen
        )
    }

    /// A rename or a queued phone prompt mid-settle must not interleave with this. Both use
    /// the same `injecting` set; this asserts the shared gate rather than trusting it.
    func testATabAlreadyInjectingIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        store.holdInjectionForTesting(id)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The gate is released by the settle, so the next tap is not locked out by the last one.
    func testTheInjectionGateIsReleasedAfterTheSettle() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(question(labels: ["Yes", "No"]),
                           with: .option(index: 1, label: "No"), in: id, token: UUID())
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(1), .ret, .ret])
    }

    // MARK: The wire

    /// The two that ack carry no code; every refusal carries one a phone can render.
    func testEveryRefusalHasItsOwnWireCode() {
        XCTAssertNil(SessionStore.AnswerDispatch.dispatched.errorCode)
        XCTAssertNil(SessionStore.AnswerDispatch.duplicate.errorCode)
        let codes: [SessionStore.AnswerDispatch] = [
            .unknownSession, .unsupportedAgent, .notWaiting, .unanswerable, .unreadableScreen,
        ]
        XCTAssertEqual(
            codes.map(\.errorCode),
            ["unknown_session", "unsupported_agent", "not_waiting", "unanswerable",
             "unreadable_screen"]
        )
    }
}
