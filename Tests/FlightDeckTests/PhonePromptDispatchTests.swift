import XCTest
@testable import FleetKit
@testable import FlightDeck

/// Which prompts reach an agent, and which are refused with a reason.
///
/// The store is the single decision point on purpose: it is the only thing that knows a tab's
/// agent, its status and whether it has a surface, and splitting those checks across
/// `FleetService` is how they drift.
@MainActor
final class PhonePromptDispatchTests: XCTestCase {
    // `StubProvider` lives in its own file now — see that file's doc comment.

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Answers `thread/name/set` so a codex tab can be created at all. Lifted from
    /// `AgentRoutingTests`, which is the only other place a test needs a real codex tab.
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

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String, background: Bool = false)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a", reportsBackgroundWork: background)
    }

    /// An idle claude tab whose injection settles synchronously, so the tests read as
    /// straight-line code. Same shape as `SessionRenameTests.makeStore`.
    private func makeStore(activity: SessionActivity = .idle, background: Bool = false)
        -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([
            1: entry(session.pinnedConversationID, activity, cwd: tmp.path, background: background)
        ])
        spy.events.removeAll()
        return (store, spy, session.id)
    }

    func testAnIdlePromptIsTypedAndSubmitted() {
        let (store, spy, id) = makeStore()
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .sent)
        XCTAssertEqual(spy.events, [.killLine, .text("ship it"), .ret])
    }

    /// The regression. `shell` means the model turn has FINISHED with a background task still
    /// running — the readiest state there is — and it was the one state we refused.
    func testIdleTabWithBackgroundWorkAcceptsAPrompt() {
        let (store, spy, id) = makeStore(activity: .idle, background: true)
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .sent)
        XCTAssertEqual(spy.events, [.killLine, .text("ship it"), .ret])
    }

    /// Still refused, and now this is the only reason: no agent process at all.
    func testATabWithNoStatusIsStillRefused() {
        let (store, _, id) = makeStore()
        store.applyRegistry([:])
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .notRunning)
        XCTAssertEqual(SessionStore.PromptDispatch.notRunning.errorCode, "not_running")
    }

    /// A prompt goes through `inject`, not through `sendToShell`: the kill-and-yank is what
    /// gives the user their half-typed draft back instead of destroying it.
    func testAOneRowDraftIsRestoredAfterThePromptIsSubmitted() {
        let (store, spy, id) = makeStore()
        spy.typeDraft(["half-written thought"])
        store.submitPrompt("ship it", token: UUID(), to: id)
        XCTAssertEqual(spy.events, [.killLine, .text("ship it"), .ret, .yank])
    }

    /// What is queued is the NORMALISED text, not the wire string. `PromptText` strips
    /// trailing newlines before it measures, so queueing the raw payload would type a
    /// trailing blank line into the input box — and would send text the length guard never
    /// actually checked. It also has to be verbatim what the phone sent, minus that strip:
    /// the outbox confirms a send by finding its own text in a transcript page.
    func testTheNormalisedTextIsWhatGetsTypedRatherThanTheRawPayload() {
        let (store, spy, id) = makeStore()
        XCTAssertEqual(store.submitPrompt("ship it\n\n", token: UUID(), to: id), .sent)
        XCTAssertEqual(spy.sent, ["ship it"])
    }

    /// **Both assertions, and the second is the one that matters.** A refusal that returned
    /// the right enum and still typed the text would pass an enum-only test — which is exactly
    /// the failure `SessionStore.rename`'s comment records for codex.
    ///
    /// What this fixture pins on its own is the *order* of the two guards: the tab has no
    /// registry status, so an implementation that asked "is there something to type into"
    /// first would answer `notRunning` — "not right now" for a tab where the answer is never.
    /// It cannot, however, catch a paste, because with no status `inject` refuses anyway;
    /// `testAnIdleCodexTabIsToldNeverRatherThanNotYet` is the fixture where the paste is
    /// reachable and the spy assertion can actually fail.
    func testACodexTabIsRefusedRatherThanPastedInto() async throws {
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
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        spy.events.removeAll()

        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .unsupportedAgent)
        XCTAssertTrue(spy.events.isEmpty,
                      "codex has no safe route: the app-server refuses a turn on a thread the "
                      + "TUI holds the writer lock on, and `InputBar` reads claude's box only")
    }

    /// **The fixture where the paste is actually reachable.** An idle codex tab clears every
    /// gate `inject` has — idle status, a readable one-row bar — so the agent guard is the
    /// only thing standing between the user's own words and a `codex resume` TUI's input
    /// box. Drop that guard here and the text is typed; drop it in
    /// `testACodexTabIsRefusedRatherThanPastedInto`, whose tab has no status, and nothing is
    /// typed because the idle gate refuses second. The two fixtures are not redundant: that
    /// one proves the guard order, this one proves the guard prevents the paste.
    func testAnIdleCodexTabIsToldNeverRatherThanNotYet() async throws {
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
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle, waitingFor: nil)])
        XCTAssertEqual(store.status(for: id)?.activity, .idle,
                       "the fixture is only meaningful if the status guard would have passed")
        spy.events.removeAll()

        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .unsupportedAgent)
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnUnknownTabIsRefused() {
        let (store, spy, _) = makeStore()
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: UUID()), .unknownSession)
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testATabWithNoAgentAtAllIsRefused() {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        // No `applyRegistry`, so the tab has no status at all — which is NOT `.idle`.
        spy.events.removeAll()

        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: session.id), .notRunning)
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnEscapeSequenceIsRefusedAndNothingIsTyped() {
        let (store, spy, id) = makeStore()
        XCTAssertEqual(
            store.submitPrompt("go\u{1b}[201~ahead", token: UUID(), to: id),
            .rejected(.controlCharacters)
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **The retry answer.** The two sends carry DIFFERENT text on purpose: a store that
    /// ignored the token would type "actually don't" as well, which a same-text fixture
    /// could not distinguish from a correct single send.
    func testTheSameTokenTwiceTypesOnce() {
        let (store, spy, id) = makeStore()
        let token = UUID()
        XCTAssertEqual(store.submitPrompt("ship it", token: token, to: id), .sent)
        XCTAssertEqual(store.submitPrompt("actually don't", token: token, to: id), .duplicate)
        XCTAssertEqual(spy.sent, ["ship it"])
    }

    /// The negative control, so the dedupe cannot pass by refusing everything after the first.
    func testADifferentTokenTypesAgain() {
        let (store, spy, id) = makeStore()
        XCTAssertEqual(store.submitPrompt("one", token: UUID(), to: id), .sent)
        XCTAssertEqual(store.submitPrompt("two", token: UUID(), to: id), .sent)
        XCTAssertEqual(spy.sent, ["one", "two"])
    }

    /// A retry is idempotent even when the text is unsendable, because the token is checked
    /// BEFORE the text is. Without that order a phone whose ack was lost would be told
    /// `prompt_control_characters` about a message the Mac already typed, which reads as
    /// "fix your text" for a send that in fact landed.
    ///
    /// The enum is deliberately the whole assertion here. "A duplicate types nothing" is
    /// `testTheSameTokenTwiceTypesOnce`'s property, and re-asserting it here would mean no
    /// mutation could tell the two tests apart — this one would only ever fail alongside it.
    func testARetryOfAnAcceptedTokenIsADuplicateRegardlessOfItsText() {
        let (store, _, id) = makeStore()
        let token = UUID()
        XCTAssertEqual(store.submitPrompt("ship it", token: token, to: id), .sent)
        XCTAssertEqual(store.submitPrompt("go\u{1b}[201~ahead", token: token, to: id), .duplicate)
    }

    /// A busy tab keeps the prompt rather than dropping it: mid-turn is when a person reaches
    /// for their phone, so this is the ordinary case rather than the edge one. And two
    /// messages are two messages, in order — which is exactly what `pendingPrompts`, being
    /// one-per-tab with replace semantics, could not have held.
    func testTwoPromptsForABusyTabBothWaitInOrder() {
        let (store, spy, id) = makeStore(activity: .busy)
        // A draft in the box, so the pair still queues: mid-turn typing is allowed into an
        // EMPTY box only, and this test is about ORDER, not about the mid-turn rule.
        spy.typeDraft(["half a thought"])
        spy.events.removeAll()
        XCTAssertEqual(store.submitPrompt("one", token: UUID(), to: id), .queued)
        XCTAssertEqual(store.submitPrompt("two", token: UUID(), to: id), .queued)
        XCTAssertTrue(spy.events.isEmpty, "nothing may be typed into a running turn")

        let queued = store.promptQueue[id] ?? []
        XCTAssertEqual(queued.count, 2, "two messages are two messages, not one replacing the other")
        guard queued.count == 2 else { return }
        XCTAssertEqual(queued.map(\.text), ["one", "two"])
    }

    /// The mapping `FleetService` reads. Asserted here rather than only end-to-end, because
    /// several of these need a Mac in a state the loopback test cannot arrange.
    func testEveryRefusalCarriesAWireCodeAndEveryAcceptanceCarriesNone() {
        XCTAssertNil(SessionStore.PromptDispatch.sent.errorCode)
        XCTAssertNil(SessionStore.PromptDispatch.queued.errorCode)
        XCTAssertNil(SessionStore.PromptDispatch.duplicate.errorCode)
        XCTAssertEqual(SessionStore.PromptDispatch.unknownSession.errorCode, "unknown_session")
        XCTAssertEqual(SessionStore.PromptDispatch.unsupportedAgent.errorCode, "unsupported_agent")
        XCTAssertEqual(SessionStore.PromptDispatch.notRunning.errorCode, "not_running")
        XCTAssertEqual(
            SessionStore.PromptDispatch.rejected(.tooLong).errorCode, "prompt_too_long"
        )
    }
}
