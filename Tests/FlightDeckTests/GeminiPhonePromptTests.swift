import FleetKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// A gemini (agy) tab's permission dialog, reaching a phone.
///
/// **What the phone could not do before.** agy keeps a waiting call in its SQLite step store and
/// never in `transcript_full.jsonl`, so the phone — which derives every card from its own copy of
/// the transcript — had nothing to derive from, and a blocked gemini tab showed "Waiting for
/// you" with no card. The Mac now sends its own derivation (`WireSession.openPrompt`), keyed on
/// `AgentOpenPromptReader.transcriptCarriesOpenPrompt`, not on the agent's name.
///
/// Wired the way `FleetService` wires it — one `PromptService` behind the store's probes — and
/// observed through a replicator, so "the phone was told" is answered by what was emitted and the
/// replicator's drift check proves the snapshot a reconnecting phone gets says the same thing.
@MainActor
final class GeminiPhonePromptTests: XCTestCase {
    private final class Sink { var events: [FleetEvent] = [] }

    private var root: URL!
    private var paths: GeminiPaths { GeminiPaths(root: root) }
    private let conversation = UUID()
    private var keep: [AnyObject] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-phone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("conversations", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        keep = []
        try? FileManager.default.removeItem(at: root)
    }

    private struct Fixture {
        let store: SessionStore
        let prompts: PromptService
        let tab: UUID
        let sink: Sink
    }

    private func standUp() -> Fixture {
        let store = SessionStore(provider: nil, persistence: nil)
        store.geminiPaths = paths
        let prompts = PromptService(store: store)
        prompts.lifecycleSink = { _ in }
        // The lines are irrelevant to agy's reader (it reads the step store); an empty tail is
        // also what a transcript with no finished step yet looks like.
        prompts.tail = { _, _ in ([], true) }
        store.openPromptProbe = { [weak prompts] in prompts?.polledOpenPrompt(inSession: $0)?.map(\.callID) }
        store.openPromptAgentProbe = { [weak prompts] in prompts?.openPromptAgent(inSession: $0) }
        store.openPromptOfferProbe = { [weak prompts] in prompts?.offeredOpenPrompt(inSession: $0) }
        let tab = store.newSession(
            in: URL(fileURLWithPath: "/tmp/project", isDirectory: true), agent: .gemini
        ).id
        store.apply(.rebound(AgentBinding(conversationID: conversation,
                                          transcriptURL: paths.transcript(conversation))), to: tab)
        let replicator = attachedReplicator(to: store)
        let sink = Sink()
        replicator.onEvents = { batch in sink.events.append(contentsOf: batch.map(\.event)) }
        keep = [store, prompts, replicator]
        return Fixture(store: store, prompts: prompts, tab: tab, sink: sink)
    }

    /// agy's step store with `call` WAITING (status 9), or answered (status 3).
    private func agyStore(waiting call: String?, tool: String = "write_to_file",
                          summary: String = "Create a.txt") throws {
        let rows: [(Int, Int, Int, Data)] = call.map { [
            (0, 14, 3, Data()),
            (1, 132, 9, GeminiAdapterTests.payload(
                callID: $0, tool: tool, args: #"{"toolSummary":"\#(summary)"}"#)),
        ] } ?? [(0, 14, 3, Data())]
        try GeminiAdapterTests.makeStore(paths.stepStore(conversation), rows: rows)
    }

    private func lastActivity(_ fixture: Fixture) -> (OpenPromptIdentity, WireOpenPrompt?)? {
        for event in fixture.sink.events.reversed() {
            if case .activityChanged(fixture.tab, _, _, _, _, let call, _, _, _, let offer) = event {
                return (call, offer)
            }
        }
        return nil
    }

    private func wireSession(_ fixture: Fixture) -> WireSession? {
        FleetProjection.snapshot(of: fixture.store).projects
            .flatMap(\.sessions).first { $0.id == fixture.tab }
    }

    func testAWaitingGeminiDialogGoesOnTheWireInWords() throws {
        let fixture = standUp()
        try agyStore(waiting: "call_9")
        fixture.store.apply(.activity(.waiting), to: fixture.tab)

        let expected = WireOpenPrompt(.permission(callID: "call_9", tool: "write_to_file",
                                                  summary: "Create a.txt"))
        let sent = try XCTUnwrap(lastActivity(fixture))
        XCTAssertEqual(sent.0, .call("call_9"))
        XCTAssertEqual(sent.1, expected)
        XCTAssertEqual(wireSession(fixture)?.openPrompt, expected,
                       "a phone that reconnects now must be told the same thing")
    }

    /// **The supersede, which is the stale-card bug.** agy answers one dialog and raises the
    /// next with the tab still `waiting`; the transcript need not move. The id and the words
    /// both move, on one event — and a closed dialog clears both.
    func testASupersededGeminiDialogReplacesItsWordsAndAClosedOneClearsThem() throws {
        let fixture = standUp()
        // A transcript on disk that never changes below, so a stamp-keyed cache would serve
        // the first dialog for the second.
        let transcript = paths.transcript(conversation)
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)

        try agyStore(waiting: "call_9")
        fixture.store.apply(.activity(.waiting), to: fixture.tab)
        XCTAssertEqual(lastActivity(fixture)?.0, .call("call_9"))

        try agyStore(waiting: "call_10", tool: "run_command", summary: "List files")
        fixture.store.apply(.activity(.waiting), to: fixture.tab)
        let superseded = try XCTUnwrap(lastActivity(fixture))
        XCTAssertEqual(superseded.0, .call("call_10"))
        XCTAssertEqual(superseded.1?.prompt,
                       .permission(callID: "call_10", tool: "run_command", summary: "List files"))

        try agyStore(waiting: nil)
        fixture.store.apply(.activity(.busy), to: fixture.tab)
        let closed = try XCTUnwrap(lastActivity(fixture))
        XCTAssertEqual(closed.0, .noPrompt)
        XCTAssertNil(closed.1, "a closed dialog leaves no words for a phone to draw")
        XCTAssertNil(wireSession(fixture)?.openPrompt)
    }

    /// The phone's answer is judged against the same derivation that was sent: the call it was
    /// shown reaches the store's dialog drive, and any other call is refused before a key moves.
    func testAnAnswerToTheSentCallReachesTheDriveAndAStaleOneIsRefused() throws {
        let fixture = standUp()
        try agyStore(waiting: "call_9")
        fixture.store.apply(.activity(.waiting), to: fixture.tab)

        let stale = fixture.prompts.answer(session: fixture.tab, agent: nil, call: "call_8",
                                           answer: .deny, token: UUID())
        XCTAssertEqual(stale.failureCode, "prompt_changed")
        // No terminal in a unit test, so the drive stops at the injector — past every check
        // that the call is the open one. `prompt_changed` here would mean the Mac could not see
        // the dialog it just sent.
        let current = fixture.prompts.answer(session: fixture.tab, agent: nil, call: "call_9",
                                             answer: .deny, token: UUID())
        XCTAssertEqual(current.failureCode, "unreadable_screen")
    }

    /// **Keyed on the capability, not the agent.** A reader whose dialog IS a transcript record
    /// is never offered, so a claude tab's wire bytes are unchanged; agy's reader is.
    func testOnlyAReaderWhoseTranscriptCannotCarryTheDialogIsOffered() throws {
        XCTAssertTrue(try XCTUnwrap(AgentID.claude.openPromptReader).transcriptCarriesOpenPrompt)
        XCTAssertTrue(try XCTUnwrap(AgentID.grok.openPromptReader).transcriptCarriesOpenPrompt)
        XCTAssertFalse(try XCTUnwrap(AgentID.gemini.openPromptReader).transcriptCarriesOpenPrompt)
    }

    /// The runtime half of the supersede: with no claude tab there is no registry tick, so the
    /// store re-derives only when the runtime reports something. A new WAITING call while the
    /// tab stays `waiting` is reported again — and an unchanged one is not.
    func testTheRuntimeReReportsWaitingWhenTheWaitingCallChanges() {
        var observation = GeminiObservation(
            held: conversation, running: true,
            pending: GeminiPendingCall(callID: "call_9", tool: "t", argumentsJSON: "{}", stepIndex: 1),
            title: nil)
        let observer = GeminiObserver(held: { _ in observation.held }, running: { _ in observation.running },
                                      pending: { _ in observation.pending }, title: { _ in observation.title })
        let runtime = GeminiRuntime(clock: nil, paths: paths, roots: { _ in [1] }, observer: observer)
        var events: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: conversation, transcriptURL: nil), for: UUID()) {
            events.append($0)
        }
        runtime.drain()
        XCTAssertEqual(events, [.lifecycle(.live), .activity(.waiting)])
        events = []
        runtime.drain()
        XCTAssertEqual(events, [], "the same dialog is not news")
        observation.pending = GeminiPendingCall(callID: "call_10", tool: "t", argumentsJSON: "{}", stepIndex: 2)
        runtime.drain()
        XCTAssertEqual(events, [.activity(.waiting)])
    }
}

private extension Result where Failure == TimelineErrorCode {
    var failureCode: String? {
        guard case .failure(let code) = self else { return nil }
        return code.code
    }
}
