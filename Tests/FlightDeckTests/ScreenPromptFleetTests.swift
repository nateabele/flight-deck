import XCTest
@testable import FleetKit
@testable import FlightDeck

/// A screen dialog through the real fleet plumbing — the replicator's drift check, the
/// `PromptService` an inbound answer is routed through, and the lifecycle log — where
/// `ScreenPromptStoreTests` stops at the store.
///
/// Two things only this layer can show: that the offer reaches the wire as a frame a client can
/// fold (a store field that moved without its event is a drift failure here), and that the log
/// records the dialog without ever writing a label or a URL into the part that goes to the
/// unified log.
@MainActor
final class ScreenPromptFleetTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 3_000_000)
    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private final class Recorder { var records: [PromptLifecycleRecord] = [] }
    private final class Sink { var events: [FleetEvent] = [] }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
    private var harness: FleetTestHarness?
    private var keep: [AnyObject] = []

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        harness?.service.stop()
        harness = nil
        keep.removeAll()
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, waitingFor: String? = nil)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: waitingFor,
              startedAt: 1, cwd: tmp.path, procStart: "start-a")
    }

    private let menu = [" Select login method:", "", " ❯ 1. Subscription", "   2. Console"]
        .joined(separator: "\n")

    // MARK: - The wire

    /// The whole path a phone depends on, over the real projection: past the debounce the tick
    /// emits one `activityChanged` carrying the screen id AND the words, and a client folding it
    /// holds a session it can draw a card for. The replicator's drift assertion is live, so a
    /// field that moved without its event fails here rather than at a handset.
    func testAScreenMenuReachesTheWireAsAnIdentityAndItsWords() throws {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.now = { [weak self] in self?.clock ?? Date() }
        let prompts = PromptService(store: store)
        prompts.lifecycleSink = { _ in }
        prompts.tail = { _, _ in ([], false) }
        keep.append(prompts)
        store.openPromptProbe = { [weak prompts] in prompts?.pushedOpenPrompt(inSession: $0).map(\.callID) }
        store.openPromptOfferProbe = { [weak prompts] in prompts?.offeredOpenPrompt(inSession: $0) }
        let spy = SpyInjector()
        spy.viewportOverride = menu
        store.injectorOverride = spy
        let session = store.newSession(in: tmp)
        let replicator = attachedReplicator(to: store)
        let sink = Sink()
        replicator.onEvents = { batch in sink.events.append(contentsOf: batch.map(\.event)) }

        let report = {
            store.applyRegistry([1: self.entry(session.pinnedConversationID, .waiting,
                                              waitingFor: "input needed")])
        }
        report()
        sink.events.removeAll()   // the first tick is the ordinary race: nothing screen-derived yet
        advance(5)
        report()

        let call = ScreenPromptID.menu(prompt: "Select login method:", labels: ["Subscription", "Console"])
        let expected = OpenPrompt.question(callID: call, [PromptQuestion(
            question: "Select login method:",
            options: [.init(label: "Subscription"), .init(label: "Console")])])
        XCTAssertEqual(sink.events.count, 1, "\(sink.events)")
        guard case .activityChanged(_, _, _, _, _, let identity, let answerless, _, _, let offer)? = sink.events.first
        else { return XCTFail("expected an activity event, got \(sink.events)") }
        XCTAssertEqual(identity, .call(call))
        XCTAssertEqual(offer, WireOpenPrompt(expected))
        XCTAssertFalse(answerless)

        let client = replicator.snapshot().fleet
        let folded = client.projects.flatMap(\.sessions).first
        XCTAssertEqual(folded?.openPromptCall, .call(call))
        XCTAssertEqual(folded?.openPrompt?.prompt, expected)
        // And a steady tick after that sends nothing: the offer is held, not re-announced.
        sink.events.removeAll()
        advance(0.5)
        report()
        XCTAssertEqual(sink.events, [])
    }

    // MARK: - Routing an answer

    /// `PromptService.answer` cannot compare a screen call against a transcript, so it hands
    /// the id to the store, which compares it against the screen. Recorded like any answer, with
    /// `open` the call this Mac believed up.
    func testAnAnswerToAScreenCallIsRoutedToTheScreenAndRecorded() throws {
        let store = SessionStore(provider: nil, persistence: nil)
        store.now = { [weak self] in self?.clock ?? Date() }
        store.promptLifecycleSink = { _ in }
        store.answerAbortSink = { _ in }
        store.injectionSettle = { $0() }
        let prompts = PromptService(store: store)
        keep.append(prompts)
        let recorder = Recorder()
        prompts.lifecycleSink = { recorder.records.append($0) }
        prompts.tail = { _, _ in ([], false) }
        store.openPromptProbe = { [weak prompts] in prompts?.pushedOpenPrompt(inSession: $0).map(\.callID) }
        store.openPromptOfferProbe = { [weak prompts] in prompts?.offeredOpenPrompt(inSession: $0) }
        let spy = SpyInjector()
        spy.showOptions(["Subscription", "Console"], selected: 0)
        store.injectorOverride = spy
        let session = store.newSession(in: tmp)
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .waiting)])
        advance(5)
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .waiting)])
        let call = try XCTUnwrap(store.openPromptCalls[session.id])
        recorder.records.removeAll()
        spy.events.removeAll()

        let ok = prompts.answer(session: session.id, agent: nil, call: call,
                                answer: .option(index: 1, label: "Console"), token: UUID())
        if case .failure(let code) = ok { XCTFail("refused: \(code.code)") }
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
        XCTAssertEqual(recorder.records.map(\.event), [.answer(sent: call, open: call, code: nil)])

        // A stale tap: the menu was replaced. `prompt_changed`, the phone's "moved on", no keys.
        spy.showOptions(["Opus", "Sonnet"], selected: 0)
        spy.events.removeAll()
        recorder.records.removeAll()
        let stale = prompts.answer(session: session.id, agent: nil, call: call,
                                   answer: .option(index: 1, label: "Console"), token: UUID())
        guard case .failure(let code) = stale else { return XCTFail("a stale tap must be refused") }
        XCTAssertEqual(code.code, "prompt_changed")
        XCTAssertEqual(spy.events, [])
        XCTAssertEqual(recorder.records.map(\.event), [.answer(sent: call, open: call, code: "prompt_changed")])
    }

    func testAScreenCallNamingASubagentIsNeverAnswered() throws {
        let store = SessionStore(provider: nil, persistence: nil)
        let prompts = PromptService(store: store)
        keep.append(prompts)
        prompts.lifecycleSink = { _ in }
        let spy = SpyInjector()
        spy.showOptions(["A", "B"], selected: 0)
        store.injectorOverride = spy
        let session = store.newSession(in: tmp)
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .waiting)])

        let result = prompts.answer(
            session: session.id, agent: "agent-123",
            call: ScreenPromptID.menu(prompt: nil, labels: ["A", "B"]),
            answer: .option(index: 0, label: "A"), token: UUID())
        guard case .failure(let code) = result else { return XCTFail("must be refused") }
        XCTAssertEqual(code.code, "prompt_changed")
        XCTAssertEqual(spy.events, [])
    }

    // MARK: - The log

    /// **Labels to the file, never the unified log.** `PromptLifecycleLog.record` sends
    /// `summary` to os_log and `summary` plus `detail` to the file, so the whole rule is that
    /// the words are in `detail` and nowhere in `summary`. A sign-in has no detail at all: its
    /// only words are its URL and the `state` inside it.
    func testTheLogNamesAScreenDialogWithoutPutALabelOrAUrlInTheSummary() throws {
        let harness = FleetTestHarness()
        self.harness = harness
        harness.store.now = { [weak self] in self?.clock ?? Date() }
        harness.store.transcriptsRootOverride = projectsRoot
        harness.store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let recorder = Recorder()
        harness.service.promptLifecycleForTesting = { recorder.records.append($0) }
        harness.service.promptTailForTesting = { _, _ in ([], false) }
        let spy = SpyInjector()
        spy.viewportOverride = menu
        harness.store.injectorOverride = spy
        let session = harness.store.newSession(in: tmp)
        let report = {
            harness.store.applyRegistry([1: self.entry(session.pinnedConversationID, .waiting,
                                                       waitingFor: "input needed")])
        }

        report()
        advance(5)
        report()

        let call = ScreenPromptID.menu(prompt: "Select login method:", labels: ["Subscription", "Console"])
        let opened = try XCTUnwrap(recorder.records.first {
            if case .opened = $0.event { return true } else { return false }
        }, "\(recorder.records.map(\.summary))")
        XCTAssertEqual(opened.event, .opened(call: call, agent: "claude", kind: .screenMenu(rows: 2)))
        XCTAssertEqual(opened.detail, "Select login method: | Subscription | Console")
        XCTAssertFalse(opened.summary.contains("Subscription"), opened.summary)
        XCTAssertFalse(opened.summary.contains("Select login"), opened.summary)
        XCTAssertTrue(opened.summary.contains("kind=screen-menu rows=2"), opened.summary)

        // And the unnameable-then-named transition is not mis-filed as a close: the dialog this
        // Mac could not name for five seconds is the one it now can.
        XCTAssertFalse(recorder.records.contains {
            if case .closed = $0.event { return true } else { return false }
        })

        // The sign-in: kind and id, no detail, and no URL or state anywhere in the line.
        spy.viewportOverride = try TimelineFixtureTests.text("login-paste-code.captured", in: "Claude")
        advance(0.5)
        report()
        let signIn = try XCTUnwrap(recorder.records.last {
            if case .opened(_, _, .signIn) = $0.event { return true } else { return false }
        }, "\(recorder.records.map(\.summary))")
        XCTAssertNil(signIn.detail)
        XCTAssertFalse(signIn.summary.contains("PLACEHOLDER"), signIn.summary)
        XCTAssertFalse(signIn.summary.contains("oauth"), signIn.summary)
        XCTAssertTrue(signIn.summary.contains("kind=signin"), signIn.summary)
        XCTAssertTrue(recorder.records.contains {
            if case .closed(let was, .superseded) = $0.event { return was == call } else { return false }
        }, "the menu was replaced by the sign-in: a supersede")
    }
}
