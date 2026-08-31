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
        store.display = DrawableDisplay()
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
        store.display = DrawableDisplay()
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
        .question(callID: "toolu_A", [PromptQuestion(
            header: "Pick", question: "Which?",
            options: labels.map { .init(label: $0) }, unanswerable: unanswerable
        )])
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

    /// **The security property on a real surface, which is what every other test here lacks.**
    ///
    /// `testAllowMovesToTheFirstRowAndReturns` and `testNoAnswerCanReachTheDontAskAgainRow`
    /// both run against `spy.showOptions`, a screen this test suite draws itself. That is
    /// enough to pin the driver's arithmetic and not enough to pin the driver against claude:
    /// a synthetic screen agrees with whatever the parser expects, by construction.
    ///
    /// This one runs against `permission-write-row2.captured.txt` — a real 2.1.241 Write
    /// dialog, captured after two Down keystrokes, so the marker is on row 2 and row 1 is the
    /// accept-edits grant. `docs/MOBILE.md` item 43 existed because nothing automated could
    /// reach this state; it can now.
    ///
    /// The assertion is the interlock, not the arithmetic: the fixture is a still image and
    /// cannot repaint, so `.allow` sends its two Ups, re-reads a screen where the marker has
    /// not moved, and presses NOTHING. A driver that trusted its own arithmetic would have
    /// pressed Return with the marker sitting on "Yes, and switch to accept edits" — granting
    /// auto-approval for the session from somebody's pocket.
    func testAllowOnACapturedClaudeDialogWillNotReturnUntilTheMarkerMoves() throws {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.viewportOverride = try TimelineFixtureTests.text(
            "permission-write-row2.captured", in: "Claude"
        )
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .dispatched
        )
        XCTAssertFalse(spy.events.contains(.ret),
                       "no Return may go out while the marker is still on the grant row")
        XCTAssertEqual(spy.events, [.arrow(-1), .arrow(-1)],
                       "two Ups for a marker on row 2, and nothing else")
    }

    /// The fixture's own shape, asserted so the test above cannot quietly stop meaning
    /// anything. If a future capture lands with the marker already on row 0, the interlock
    /// test would pass for the wrong reason — it would send no arrows and press no Return
    /// because there was nothing to do.
    func testTheCapturedClaudeDialogReallyHasItsMarkerOffTheFirstRow() throws {
        let screen = try TimelineFixtureTests.text("permission-write-row2.captured", in: "Claude")
        XCTAssertTrue(screen.contains("  1. Yes"), "row 0 is present and unmarked")
        XCTAssertTrue(screen.contains("❯ 3. No"), "the marker is on the third row")
        XCTAssertTrue(
            screen.contains("2. Yes, and switch to accept edits"),
            "row 1 is the grant this must never land on"
        )
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
        for activity in [SessionActivity.idle, .busy] {
            let (store, spy, id) = makeStore(activity: activity)
            spy.showOptions(["Yes"], selected: 0)
            XCTAssertEqual(
                store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .notWaiting
            )
            XCTAssertTrue(spy.events.isEmpty, "\(activity) must send nothing, not even Escape")
        }
    }

    /// **The refusal these two tests used to assert is gone, deliberately.** They read
    /// `unsupportedAgent` for a codex tab, on the reasoning that codex had no dialog this
    /// build had ever read. Five verbatim codex-cli 0.148.0 screens now say otherwise, and
    /// `CodexDialogDriver` is that reading — so what refuses a codex tab here is the ordinary
    /// status gate, exactly as it refuses a claude one.
    ///
    /// The ordering property the first of them pinned — agent before status, so a tab that
    /// can never be answered hears "never" rather than "not right now" — is no longer
    /// falsifiable by fixture, because both shipped agents now have a driver. It is stated in
    /// `answerPrompt`'s doc and would need a third agent to test. Recorded rather than
    /// deleted quietly.
    func testAnIdleCodexTabIsRefusedByTheStatusGateLikeAnyOther() async throws {
        let (store, spy, id) = try await makeCodexStore(activity: .idle)
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .notWaiting
        )
        XCTAssertTrue(spy.events.isEmpty, "idle must send nothing, not even Escape")
    }

    /// **Deny on codex is one Escape, and codex's own footer says so** — `Press enter to
    /// confirm or esc to cancel`, on every captured approval. It reads nothing at all, which
    /// is why it is the one answer that works on a screen no parser can make sense of; here
    /// the spy's screen is deliberately unreadable to prove that.
    func testAWaitingCodexTabIsDeniedWithASingleEscape() async throws {
        let (store, spy, id) = try await makeCodexStore(activity: .waiting)
        spy.viewportIsReadable = false
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.escape])
    }

    /// **Allow, driven off the screen codex actually printed.** The cursor opens on row 0,
    /// `CodexDialogDriver.allowRow` is 0, so no arrow is sent; the re-read confirms the
    /// marker is still on row 0 and only then does Return go out.
    func testAllowOnACapturedCodexApprovalPressesReturnWithoutMoving() async throws {
        let (store, spy, id) = try await makeCodexStore(activity: .waiting)
        spy.viewportOverride = try TimelineFixtureTests.text(
            "approval-command.captured", in: "Codex"
        )
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.ret], "row 0 is already the plain approval; nothing moves")
    }

    /// **The re-read interlock, on the only fixture pair in the repo that can prove it.**
    /// `approval-command-row1` is the same dialog after one Down, so the cursor is on the
    /// DURABLE GRANT. Allow sends one Up — and then re-reads a screen that has not repainted,
    /// finds the marker still on row 1, and presses nothing. A driver that trusted its own
    /// arithmetic would have granted "don't ask again for commands that start with
    /// `mkdir -p …`" from somebody's pocket.
    func testAllowOnACodexDialogDoesNotReturnUntilTheMarkerHasActuallyMoved() async throws {
        let (store, spy, id) = try await makeCodexStore(activity: .waiting)
        spy.viewportOverride = try TimelineFixtureTests.text(
            "approval-command-row1.captured", in: "Codex"
        )
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(-1)],
                       "the marker did not move, so no Return may follow")
    }

    /// **The marker is per-agent, and this is what a defaulted one would have hidden.** A
    /// claude tab handed codex's captured approval finds no list at all — `❯` (U+276F) is not
    /// `›` (U+203A) — so it refuses rather than driving somebody else's dialog.
    func testAClaudeTabRefusesACodexScreen() throws {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.viewportOverride = try TimelineFixtureTests.text(
            "approval-command.captured", in: "Codex"
        )
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
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
        store.display = DrawableDisplay()
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
