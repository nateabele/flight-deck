import FleetKit
import XCTest
@testable import FlightDeck

/// The type that turns "a phone tapped a button" into "the Mac drove its own terminal".
///
/// **Its entire job is the re-derivation**, and that is the property most of this file asserts:
/// the open call is recomputed from the transcript on every answer, and a call that is no
/// longer the newest unanswered one is refused. A cache would be faster and would not close
/// the race this exists for.
///
/// **Every fixture that must refuse puts a live dialog on the spy's screen**, and that is not
/// decoration. With no list up, `SessionStore.answerPrompt` refuses on its own — so a test
/// whose service dropped the call-id comparison would still be green, and `spy.events.isEmpty`
/// would be asserting the screen rather than the guard. With the list up, a service that
/// answered the wrong call types.
@MainActor
final class PromptServiceTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Answers `thread/name/set` so a codex tab can be created at all. Lifted from
    /// `AnswerPromptTests`, which needs a real codex tab for the same reason.
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
    /// was building it for rather than returning a service nothing was set up on.
    private struct CodexTabUnavailable: Error {}

    /// Counts the reads the seam performed. `PromptService.tail` is `@Sendable`, so a captured
    /// `var` cannot be mutated from inside one; every call arrives on the main actor, inline
    /// from `answer`, which is what `@unchecked` records here.
    private final class ReadCount: @unchecked Sendable {
        var value = 0
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

    /// A claude tab whose injection settles synchronously, so the tests read as straight-line
    /// code — `AnswerPromptTests.makeStore`, plus the service under test.
    private func makeService(activity: SessionActivity)
        -> (PromptService, SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        // Silenced: the production sink appends to the developer's own
        // `~/Library/Logs/flight-deck-prompt.log`, and every refusal these tests provoke on
        // purpose would land in it. `PromptLifecycleTests` is where the records are asserted.
        let service = PromptService(store: store)
        service.lifecycleSink = { _ in }
        return (service, store, spy, session.id)
    }

    /// A codex tab, given a status directly because no claude registry describes one.
    private func makeCodexService(activity: SessionActivity) async throws
        -> (PromptService, SessionStore, SpyInjector, UUID) {
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
        // Silenced: the production sink appends to the developer's own
        // `~/Library/Logs/flight-deck-prompt.log`, and every refusal these tests provoke on
        // purpose would land in it. `PromptLifecycleTests` is where the records are asserted.
        let service = PromptService(store: store)
        service.lifecycleSink = { _ in }
        return (service, store, spy, id)
    }

    /// The wire code an answer came back with, or `nil` for success.
    ///
    /// `Result<Void, _>` is not `Equatable` — `Void` is not — so the assertions read the code
    /// out rather than comparing whole results. `nil` for success is the spelling
    /// `AnswerDispatch.errorCode` already uses, and the one `FleetService`'s command arm
    /// reads.
    private func code(_ result: Result<Void, TimelineErrorCode>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.code
    }

    private func askLine(_ id: String, multiSelect: Bool = false) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"AskUserQuestion","input":{"questions":[{"question":"Which?",\
        "multiSelect":\(multiSelect),"options":[{"label":"Yes"},{"label":"No"}]}]}}]}}
        """
    }

    private func bashLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"rm -rf build"}}]}}
        """
    }

    private func resultLine(_ id: String) -> String {
        """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"\(id)","content":"done"}]}}
        """
    }

    func testAnsweringTheOpenQuestionDrivesTheTerminal() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        let lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        service.tail = { _, _ in lines }
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertNil(
            code(service.answer(session: id, call: "toolu_A",
                                answer: .option(index: 1, label: "No"), token: UUID()))
        )
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    /// **Racing the Mac, the simple case.** The user answered in the terminal, so the call the
    /// phone named now has a result and there is no open call at all — while the dialog the
    /// terminal has moved on to is still up on screen, which is what makes "nothing was typed"
    /// mean something here.
    func testAnAnswerToACallThatHasSinceBeenAnsweredIsRefused() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        let lines = [
            SourceLine(offset: 0, text: askLine("toolu_A")),
            SourceLine(offset: 100, text: resultLine("toolu_A")),
        ]
        service.tail = { _, _ in lines }
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            code(service.answer(session: id, call: "toolu_A",
                                answer: .option(index: 0, label: "Yes"), token: UUID())),
            "prompt_changed"
        )
        XCTAssertTrue(spy.events.isEmpty, "an answered call is not answered a second time")
    }

    /// **Racing the Mac, the hard case — and the one a cache would not have caught.** The user
    /// approves prompt 1 in the terminal, claude raises prompt 2 immediately, and the session
    /// NEVER leaves `waiting`, so the phone's card can still be showing prompt 1 when a thumb
    /// comes down. A stale tap must not approve prompt 2, which nobody read.
    ///
    /// `WireSession.openPromptCall` pushes that supersede now, so the card should be gone by
    /// the time a finger reaches it — which makes this rarer and not one bit less necessary.
    /// The frame can be in flight, dropped, or ignored; this refusal is what stands between
    /// any of those and a keystroke at a real terminal.
    ///
    /// The spy is showing prompt 2's dialog, so the refusal has to come from the call-id
    /// comparison: a service that dropped it would find prompt 2, be handed a screen it can
    /// read perfectly well, and press Return on it.
    func testAnAnswerToASupersededCallIsRefusedEvenWhileStillWaiting() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        let lines = [
            SourceLine(offset: 0, text: bashLine("toolu_ONE")),
            SourceLine(offset: 100, text: resultLine("toolu_ONE")),
            SourceLine(offset: 200, text: bashLine("toolu_TWO")),
        ]
        service.tail = { _, _ in lines }
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            code(service.answer(session: id, call: "toolu_ONE", answer: .allow, token: UUID())),
            "prompt_changed"
        )
        XCTAssertTrue(spy.events.isEmpty, "nothing may be typed at a dialog nobody read")
    }

    /// **The same race, from the phone's second tap** — and the sequence a cache is built
    /// out of. The phone answers prompt 1 and it lands; the terminal moves to prompt 2 with
    /// the session never leaving `waiting`, so the card is never torn down; the phone's
    /// deadline elapses and a thumb comes down on it again. A service holding what it last
    /// served would still match prompt 1 and would press Return on prompt 2 — which is up on
    /// screen here, so a mutation that answers it types rather than merely returning the
    /// wrong code.
    func testASecondTapOnTheSameCardIsRefusedOnceTheDialogHasMovedOn() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        let one = [SourceLine(offset: 0, text: bashLine("toolu_ONE"))]
        let two = one + [
            SourceLine(offset: 100, text: resultLine("toolu_ONE")),
            SourceLine(offset: 200, text: bashLine("toolu_TWO")),
        ]
        spy.showOptions(["Yes", "No"], selected: 0)

        service.tail = { _, _ in one }
        XCTAssertNil(code(service.answer(session: id, call: "toolu_ONE", answer: .allow,
                                         token: UUID())))
        XCTAssertEqual(spy.events, [.ret], "the first tap is the one that lands")

        spy.events.removeAll()
        service.tail = { _, _ in two }
        XCTAssertEqual(
            code(service.answer(session: id, call: "toolu_ONE", answer: .allow, token: UUID())),
            "prompt_changed"
        )
        XCTAssertTrue(spy.events.isEmpty, "the card is stale; prompt 2 is not what was read")
    }

    /// **The refusal that has to be its own sentence.** `OpenPrompt.find` gates on `waiting`
    /// too, and `SessionStore.answerPrompt` gates on it a third time, so an idle session is
    /// refused three ways over — but only this service's guard can say *why*. Without it the
    /// phone is told the prompt changed when what happened is that nothing is blocked.
    func testAnAnswerWhileNothingIsOpenIsRefused() {
        let (service, _, spy, id) = makeService(activity: .idle)
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_A"))]
        service.tail = { _, _ in lines }
        XCTAssertEqual(
            code(service.answer(session: id, call: "toolu_A", answer: .deny, token: UUID())),
            "not_waiting"
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnUnknownSessionIsRefused() {
        let (service, _, _, _) = makeService(activity: .waiting)
        XCTAssertEqual(
            code(service.answer(session: UUID(), call: "toolu_A", answer: .deny, token: UUID())),
            "unknown_session"
        )
    }

    /// **The re-derivation happens on every answer, not once.** Two answers, two reads. A
    /// service that cached the first derivation would read once and would then be answering
    /// from a picture of the past — which is the whole failure the hard-race test above
    /// describes.
    func testTheOpenCallIsRederivedOnEveryAnswer() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_A"))]
        let reads = ReadCount()
        service.tail = { _, _ in
            reads.value += 1
            return lines
        }
        XCTAssertNil(code(service.answer(session: id, call: "toolu_A", answer: .deny,
                                         token: UUID())))
        XCTAssertNil(code(service.answer(session: id, call: "toolu_A", answer: .deny,
                                         token: UUID())))
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(spy.events, [.escape, .escape], "both answers were carried out")
    }

    /// **A refusal the store makes is forwarded verbatim, not flattened into this service's
    /// own.** `unanswerable` sends a reader somewhere entirely different from
    /// `prompt_changed`: the dialog is exactly the one they are looking at, and it has to be
    /// answered at the Mac. The shape is a multi-select question, which is the real thing
    /// `PromptQuestion` refuses.
    func testARefusalFromTheStoreKeepsItsOwnCode() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        let lines = [SourceLine(offset: 0, text: askLine("toolu_A", multiSelect: true))]
        service.tail = { _, _ in lines }
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            code(service.answer(session: id, call: "toolu_A",
                                answer: .option(index: 0, label: "Yes"), token: UUID())),
            "unanswerable"
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// A retry of an answer that already landed is a success, not an error. The phone re-sends
    /// on its own deadline (`SessionTimelineModel.noConfirmation`), and `AnswerDispatch`
    /// deliberately calls that `duplicate` with no error code — a refusal here would draw an
    /// error over an answer that worked.
    func testARetryOfAnAnswerThatLandedIsNotAnError() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_A"))]
        service.tail = { _, _ in lines }
        let token = UUID()
        XCTAssertNil(code(service.answer(session: id, call: "toolu_A", answer: .deny,
                                         token: token)))
        XCTAssertNil(code(service.answer(session: id, call: "toolu_A", answer: .deny,
                                         token: token)))
        XCTAssertEqual(spy.events, [.escape], "the retry is answered, not carried out twice")
    }

    /// **A codex tab is told the true reason, and `prompt_changed` is not it.**
    ///
    /// This line used to answer `prompt_changed` for every non-claude tab, which the phone
    /// renders as *"Your Mac has moved on from this."* — a sentence about a dialog that
    /// moved, offered for a tab whose dialog did not move and never could be answered. It
    /// reads as transient, so it invites a retry that can never succeed. `unsupported_agent`
    /// is the code `SessionStore.answerPrompt` already defines for exactly this and the phone
    /// already has copy for, and routing it here is what lets that copy ever appear.
    ///
    /// **The refusal moved, and the code did not.** It was `dialogDriver` alone; codex now
    /// has one, so what refuses here is `AgentAdapter.openPromptReader` — this file's own
    /// half. Driving a dialog needs a screen grammar, and codex has one; knowing WHICH dialog
    /// is up needs a transcript grammar, and codex writes nothing to its rollout when an
    /// approval goes up, so there is no call id for a phone's tap to be checked against.
    /// Both are asked of the same adapter, not re-decided here.
    ///
    /// The tail is deliberately claude-shaped records rather than nothing: that distinguishes
    /// "the file was never read" from "it was read and held no call", and a service that
    /// pointed the claude mapper at a codex transcript would find a call in this fixture. So
    /// a service that dropped this guard would fall through and answer `prompt_changed` from
    /// the *next* one, which is what the old assertion could not tell apart.
    func testACodexTabIsRefusedAsUnsupportedRatherThanAsChanged() async throws {
        let (service, _, spy, id) = try await makeCodexService(activity: .waiting)
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_A"))]
        service.tail = { _, _ in lines }
        XCTAssertEqual(
            code(service.answer(session: id, call: "toolu_A", answer: .deny, token: UUID())),
            "unsupported_agent"
        )
        XCTAssertTrue(
            spy.events.isEmpty,
            "no Escape at a dialog this build cannot identify — the driver could press the "
            + "key, which is exactly why the second half of the question has to be asked"
        )
    }

    /// **The case that actually pins this file's guard, and the one above does not.**
    ///
    /// A coverage gap found by mutation: deleting the capability guard from `PromptService`
    /// entirely leaves the whole 1687-test suite green, because the tab in the test above has
    /// a real `.file(.codex, url)` source, so a service without the guard falls through to
    /// `SessionStore.answerPrompt` — which has a capability guard of its own and answers
    /// `unsupported_agent` anyway. That test was measuring the store's refusal forwarded
    /// through this file, not this file's.
    ///
    /// A codex **sign-in tab** is the shape that tells them apart, and it is the shape this
    /// guard's own comment names: `openSignInSession` mints a tab with no `transcriptPath`,
    /// so `timelineSource` answers `.noTranscript`, so a service without the guard never
    /// reaches the store at all — it falls to `prompt_changed`, the sentence about a dialog
    /// that moved, for a tab that never had one.
    func testACodexSignInTabIsRefusedAsUnsupportedRatherThanAsChanged() {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        // A store with no `PreferencesStore` resolves every tab to the nil account, whatever
        // the sign-in account's own id is — which is the key this override has to be filed
        // under, and for codex a miss means building a real stack.
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedCodexTransport())),
            for: .codex, account: nil
        )
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let account = AgentAccount(
            agent: .codex, displayName: "signing in",
            home: projectsRoot.appendingPathComponent("codex-home", isDirectory: true)
        )
        let session = store.openSignInSession(
            for: account, in: tmp.path,
            using: LoginInvocation(command: "codex login", inject: nil)
        )
        // The tab has to be waiting, or `not_waiting` refuses first and this proves nothing.
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .waiting)])
        spy.events.removeAll()

        let service = PromptService(store: store)
        service.lifecycleSink = { _ in }
        // Non-empty, so a service that reached the read would find a call rather than being
        // saved by an empty tail — the distinction `prompt_changed` would otherwise hide.
        // Built out here rather than inside the `@Sendable` seam, which cannot reach `self`.
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_A"))]
        service.tail = { _, _ in lines }

        XCTAssertEqual(
            code(service.answer(session: session.id, call: "toolu_A", answer: .deny, token: UUID())),
            "unsupported_agent"
        )
        XCTAssertTrue(spy.events.isEmpty, "no Escape into a codex TUI this build cannot read")
    }

}
