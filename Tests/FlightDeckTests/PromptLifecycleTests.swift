import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// What this Mac records about a dialog opening, closing and being answered.
///
/// **Diagnostics, and the assertions are about the record rather than about behaviour.** The
/// question this log exists to settle is whether a closure the phone never applied ever left
/// the Mac at all, and the two facts that answer it are the ones asserted hardest here: the
/// call-id pairing on a refused answer (`sent` beside `open`), and the client count on the
/// push that carried the transition.
///
/// Nothing here may become a behavioural test. `AnswerLoopbackTests` and `PromptServiceTests`
/// own what the answer path *does*; if a change to logging moved a keystroke, it is those
/// files that must fail, not this one.
@MainActor
final class PromptLifecycleTests: XCTestCase {
    private final class Recorder {
        var records: [PromptLifecycleRecord] = []
        var events: [PromptLifecycleRecord.Event] { records.map(\.event) }
    }

    /// The transcript the tail seam serves, mutable between phases of one test.
    ///
    /// `PromptService.tail` is `@Sendable`, so a captured `var` cannot be written from inside
    /// one; every call arrives on the main actor, inline from the observer, which is what
    /// `@unchecked` records here — the same arrangement `PromptServiceTests.ReadCount` uses.
    private final class Transcript: @unchecked Sendable {
        var lines: [SourceLine] = []
        var reads = 0
    }

    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Answers `thread/start` so a codex tab can be created at all — lifted from
    /// `PromptServiceTests`, which needs a real codex tab for the same reason. The rollout path
    /// this answers with does not exist on disk, so the adapter is built below with
    /// `rolloutExists` stubbed true, or `prepare`'s history-contract check trips before this
    /// test ever gets to the refusal it is checking.
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

    private struct CodexTabUnavailable: Error {}

    private var harness: FleetTestHarness?
    private var client: FleetClient?
    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        client?.disconnect()
        harness?.service.stop()
        client = nil
        harness = nil
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    // MARK: - Fixtures

    private func entry(
        _ sid: UUID, _ activity: SessionActivity, cwd: String, waitingFor: String? = nil
    ) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: waitingFor,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// The three options of `Fixtures/Claude/question-single.captured.jsonl`, in its order.
    private static let options = ["Rust", "Go", "Swift"]

    private func askLine(_ id: String, options: [String] = PromptLifecycleTests.options) -> String {
        let rendered = options.map { #"{"label":"\#($0)"}"# }.joined(separator: ",")
        return """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"AskUserQuestion","input":{"questions":[{"question":"Which?",\
        "multiSelect":false,"options":[\(rendered)]}]}}]}}
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

    /// A claude tab under a real `FleetService`, with the transcript tail substituted and the
    /// lifecycle sink recording. The tab starts with no status at all, so every test drives
    /// the edge it is about rather than inheriting one.
    private func standUp() -> (Recorder, Transcript, UUID) {
        let harness = FleetTestHarness()
        self.harness = harness
        harness.store.transcriptsRootOverride = projectsRoot
        harness.store.codexIndexURLOverride =
            projectsRoot.appendingPathComponent("session_index.jsonl")
        let recorder = Recorder()
        harness.service.promptLifecycleForTesting = { recorder.records.append($0) }
        let transcript = Transcript()
        harness.service.promptTailForTesting = { _, _ in
            transcript.reads += 1
            return transcript.lines
        }
        let session = harness.store.newSession(in: tmp)
        // The tab's own creation must say nothing: a session that has never been `waiting` has
        // never had a dialog, and one line per restored tab at launch would drown the file.
        XCTAssertEqual(recorder.records.count, 0)
        return (recorder, transcript, session.id)
    }

    /// Drives one registry tick for the tab, which is what produces the `activityChanged`
    /// event the observer reads.
    private func report(_ activity: SessionActivity, waitingFor: String? = nil) {
        guard let harness, let session = harness.store.repos.flatMap(\.sessions).first else {
            return XCTFail("the fixture must have exactly one tab")
        }
        harness.store.applyRegistry(
            [1: entry(session.pinnedConversationID, activity, cwd: tmp.path,
                      waitingFor: waitingFor)]
        )
    }

    // MARK: - Opening

    func testEnteringWaitingRecordsTheOpenQuestionAndThePushThatCarriedIt() throws {
        let (recorder, transcript, _) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]

        report(.waiting)

        XCTAssertEqual(recorder.events, [
            .opened(call: "toolu_A", agent: "claude", kind: .question(options: [3])),
            // Nobody is attached, which is itself the finding when a card outlives its dialog.
            .pushed(asserts: .open, activity: "waiting", clients: 0),
        ])
    }

    /// A permission dialog has no options to count, so the record names the tool instead —
    /// which is all `OpenPrompt.permission` has and all the phone's card gets either.
    func testAPermissionDialogRecordsItsToolRatherThanOptionCounts() throws {
        let (recorder, transcript, _) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: bashLine("toolu_BASH"))]

        report(.waiting)

        XCTAssertEqual(recorder.events.first, .opened(
            call: "toolu_BASH", agent: "claude", kind: .permission(tool: "Bash")
        ))
    }

    /// **Report 1 and report 4's Mac-side signature.** The session says "waiting", the phone
    /// draws a card, and this Mac cannot name the dialog it is drawing — so every tap on it
    /// will be refused. The push still asserts a dialog is open, because that is genuinely
    /// what went out.
    func testWaitingWithNothingDerivableRecordsUnnamedAndStillPushesOpen() throws {
        let (recorder, _, _) = standUp()

        report(.waiting)

        XCTAssertEqual(recorder.events, [
            .unnamed(code: "prompt_changed"),
            .pushed(asserts: .open, activity: "waiting", clients: 0),
        ])
    }

    // MARK: - Closing

    func testLeavingWaitingRecordsTheCloseAndTheAbsentPush() throws {
        let (recorder, transcript, _) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        report(.waiting)
        recorder.records.removeAll()

        report(.idle)

        XCTAssertEqual(recorder.events, [
            .closed(call: "toolu_A", reason: .activity("idle")),
            .pushed(asserts: .absent, activity: "idle", clients: 0),
        ])
    }

    /// **The transition this log was built to catch.** claude answers one dialog and raises
    /// the next without the session leaving `waiting`, so the frame that goes out still says
    /// `waiting` exactly as the last one did. The absence of a `pushed` record here is the
    /// assertion, and it still is: `pushed` reports the `waiting` claim a card's *existence*
    /// rests on, which genuinely did not move.
    ///
    /// What did move is `openPromptCall`, which now rides on that same frame — see
    /// `PromptIdentityWireTests`, which owns what the fleet sends. Nothing here may become a
    /// test of that.
    func testANewCallWhileStillWaitingRecordsASupersedeAndNoPush() throws {
        let (recorder, transcript, _) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        report(.waiting)
        recorder.records.removeAll()

        transcript.lines = [
            SourceLine(offset: 0, text: askLine("toolu_A")),
            SourceLine(offset: 1, text: resultLine("toolu_A")),
            SourceLine(offset: 2, text: bashLine("toolu_B")),
        ]
        // Still waiting; only the reason moved. This observer reads the fleet's own outbound
        // events, so it can only see a tick that produced one — which is why the reason is
        // moved here rather than held fixed.
        report(.waiting, waitingFor: "permission prompt")

        XCTAssertEqual(recorder.events, [
            .closed(call: "toolu_A", reason: .superseded(call: "toolu_B")),
            .opened(call: "toolu_B", agent: "claude", kind: .permission(tool: "Bash")),
        ])
    }

    /// The dialog was answered at the keyboard, the session has not moved off `waiting` yet,
    /// and the Mac can no longer name a call. A phone still holding that card is now stale and
    /// nothing was sent to say so.
    func testLosingTheOpenCallWhileStillWaitingRecordsTheCloseAsUnnamed() throws {
        let (recorder, transcript, _) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        report(.waiting)
        recorder.records.removeAll()

        transcript.lines = [
            SourceLine(offset: 0, text: askLine("toolu_A")),
            SourceLine(offset: 1, text: resultLine("toolu_A")),
        ]
        report(.waiting, waitingFor: "input needed")

        XCTAssertEqual(recorder.events, [
            .closed(call: "toolu_A", reason: .unnamed(code: "prompt_changed")),
        ])
    }

    func testClosingATabWithAnOpenDialogRecordsTheCloseAndTheAbsentPush() throws {
        let (recorder, transcript, id) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        report(.waiting)
        recorder.records.removeAll()

        harness?.store.closeSession(id)

        XCTAssertEqual(recorder.events, [
            .closed(call: "toolu_A", reason: .sessionRemoved),
            .pushed(asserts: .absent, activity: nil, clients: 0),
        ])
    }

    /// A tab that never had a dialog says nothing when it goes away, because there is nothing
    /// about a prompt to say. Without this the log is one line per closed tab.
    func testClosingAnIdleTabRecordsNothing() throws {
        let (recorder, _, id) = standUp()
        report(.idle)
        recorder.records.removeAll()

        harness?.store.closeSession(id)

        XCTAssertEqual(recorder.events, [])
    }

    /// Two ticks that say the same thing produce one record between them. A log proportional
    /// to polls rather than to dialogs is a log nobody reads.
    func testARepeatedWaitingTickRecordsNothingFurther() throws {
        let (recorder, transcript, _) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        report(.waiting)
        recorder.records.removeAll()

        report(.waiting)
        report(.waiting)

        XCTAssertEqual(recorder.events, [])
    }

    // MARK: - Agents this build cannot read

    /// **The derivation must not be the thing that builds an adapter.** A codex tab is refused
    /// on the agent alone, before `PromptService.openPrompt` resolves a transcript — that
    /// resolution memoizes a whole `CodexStack`, and a log line has no business creating one.
    /// The read count is what proves the early return; the code is what proves it is the same
    /// refusal a tap would get.
    func testACodexTabIsRecordedUnnamedWithoutReadingATranscript() async throws {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.launchFailureReporter = SilentReporter()
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedCodexTransport()), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )
        let harness = FleetTestHarness(store: store)
        self.harness = harness
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let recorder = Recorder()
        harness.service.promptLifecycleForTesting = { recorder.records.append($0) }
        let transcript = Transcript()
        transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        harness.service.promptTailForTesting = { _, _ in
            transcript.reads += 1
            return transcript.lines
        }
        guard case .success(let id) = await store.createSession(agent: .codex, in: tmp.path) else {
            XCTFail("codex tab creation must succeed against a scripted transport")
            throw CodexTabUnavailable()
        }
        recorder.records.removeAll()

        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])

        XCTAssertEqual(recorder.events, [
            .unnamed(code: "unsupported_agent"),
            .pushed(asserts: .open, activity: "waiting", clients: 0),
        ])
        XCTAssertEqual(transcript.reads, 0, "no transcript may be read for an agent this build cannot name a dialog for")
    }

    // MARK: - Inbound answers

    /// A standalone service, as `PromptServiceTests` builds one: the answer path is reached
    /// through `PromptService` from both the socket and `AnswerTrigger`, so one record covers
    /// both and neither needs a fleet.
    private func makeService(activity: SessionActivity)
        -> (PromptService, Recorder, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.answerAbortSink = { _ in }
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        let service = PromptService(store: store)
        let recorder = Recorder()
        service.lifecycleSink = { recorder.records.append($0) }
        return (service, recorder, spy, session.id)
    }

    /// **The line this whole task exists for.** The client named one call, the Mac believes
    /// another is open, and both strings are in one record — which is what tells "the phone
    /// was stale" apart from "the Mac forgot".
    func testARefusedAnswerRecordsTheCallSentBesideTheCallOpen() throws {
        let (service, recorder, spy, id) = makeService(activity: .waiting)
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_OPEN"))]
        service.tail = { _, _ in lines }
        // A live dialog on screen, so the refusal comes from the comparison rather than from a
        // screen nothing could read — the trap `PromptServiceTests` documents at length.
        spy.showOptions(["Yes", "No"], selected: 0)

        _ = service.answer(session: id, call: "toolu_STALE", answer: .allow, token: UUID())

        XCTAssertEqual(recorder.events, [
            .answer(sent: "toolu_STALE", open: "toolu_OPEN", code: "prompt_changed"),
        ])
    }

    /// The shape the reported failure produced: the phone had a card, the Mac had no dialog at
    /// all. `open=none` is not the same fault as `open=<another call>` and must not read the
    /// same way.
    func testAnAnswerAgainstATabWithNoOpenDialogRecordsOpenAsNone() throws {
        let (service, recorder, _, id) = makeService(activity: .idle)

        _ = service.answer(session: id, call: "toolu_GHOST", answer: .allow, token: UUID())

        XCTAssertEqual(recorder.events, [
            .answer(sent: "toolu_GHOST", open: nil, code: "not_waiting"),
        ])
    }

    /// Accepted answers are recorded too. Without this line, a log holding no refusal cannot be
    /// told apart from one where the tap never reached the Mac.
    func testAnAcceptedAnswerRecordsTheMatchingCallWithNoCode() throws {
        let (service, recorder, spy, id) = makeService(activity: .waiting)
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_BASH"))]
        service.tail = { _, _ in lines }
        spy.showOptions(["Yes", "No"], selected: 0)

        _ = service.answer(session: id, call: "toolu_BASH", answer: .allow, token: UUID())

        XCTAssertEqual(recorder.events, [
            .answer(sent: "toolu_BASH", open: "toolu_BASH", code: nil),
        ])
        XCTAssertEqual(spy.events, [.ret], "the drive itself must be untouched by the logging")
    }

    /// A refusal the store makes after the call ids matched is still recorded against the pair,
    /// because "the right dialog, refused for another reason" is a third outcome and reads
    /// nothing like the other two.
    func testAStoreRefusalAfterAMatchingCallIsRecordedWithItsOwnCode() throws {
        let (service, recorder, spy, id) = makeService(activity: .waiting)
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_BASH"))]
        service.tail = { _, _ in lines }
        // The screen cannot be read at all, so the store refuses after the call ids matched.
        spy.viewportIsReadable = false

        _ = service.answer(session: id, call: "toolu_BASH", answer: .allow, token: UUID())

        XCTAssertEqual(recorder.events, [
            .answer(sent: "toolu_BASH", open: "toolu_BASH", code: "unreadable_screen"),
        ])
    }

    // MARK: - Over a real socket

    /// The client count, proved against an actual attachment rather than a stub, plus what a
    /// reattaching client is handed. Those two numbers are the difference between "the closure
    /// went out and was ignored" and "there was nobody to send it to".
    func testAnAttachedClientIsCountedOnThePushAndOnTheResume() async throws {
        let (recorder, transcript, _) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        let harness = try XCTUnwrap(self.harness)
        let port = try await harness.start()

        let client = FleetClient(key: harness.key)
        self.client = client
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        let attached = expectation(description: "attached")
        let observer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !harness.service.attachedSlots.isEmpty { attached.fulfill() }
            }
        }
        await fulfillment(of: [attached], timeout: 10)
        observer.invalidate()

        // The `hello` is answered before any dialog exists, so the resume asserts none.
        XCTAssertEqual(recorder.events, [
            .resumed(lastSeq: 0, mode: "snapshot-initial", frames: 1, waiting: 0, clients: 1),
        ])
        recorder.records.removeAll()

        report(.waiting)

        XCTAssertEqual(recorder.events, [
            .opened(call: "toolu_A", agent: "claude", kind: .question(options: [3])),
            .pushed(asserts: .open, activity: "waiting", clients: 1),
        ])
    }

    // MARK: - The record's own text

    /// Pinned verbatim, because these lines are read by a person in `Console.app` and in a
    /// `tail -f`, and a field that quietly changed name breaks every note anyone wrote about
    /// how to read them.
    func testEverySummaryReadsAsOneShortLine() {
        let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let cases: [(PromptLifecycleRecord.Event, String)] = [
            (.opened(call: "toolu_A", agent: "claude", kind: .question(options: [3, 2])),
             "opened call=toolu_A agent=claude kind=question questions=2 options=3,2"),
            (.opened(call: "toolu_B", agent: "claude", kind: .permission(tool: "Bash")),
             "opened call=toolu_B agent=claude kind=permission tool=Bash"),
            (.closed(call: "toolu_A", reason: .activity("idle")),
             "closed call=toolu_A reason=activity-idle"),
            (.closed(call: "toolu_A", reason: .activity(nil)),
             "closed call=toolu_A reason=activity-none"),
            (.closed(call: "toolu_A", reason: .superseded(call: "toolu_B")),
             "closed call=toolu_A reason=superseded-by-toolu_B"),
            (.closed(call: "toolu_A", reason: .unnamed(code: "prompt_changed")),
             "closed call=toolu_A reason=unnamed-prompt_changed"),
            (.closed(call: "toolu_A", reason: .sessionRemoved),
             "closed call=toolu_A reason=session-removed"),
            (.unnamed(code: "unsupported_agent"), "unnamed code=unsupported_agent"),
            (.pushed(asserts: .open, activity: "waiting", clients: 2),
             "push asserts=open activity=waiting clients=2"),
            (.pushed(asserts: .absent, activity: nil, clients: 0),
             "push asserts=absent activity=- clients=0"),
            (.resumed(lastSeq: 12, mode: "replay", frames: 3, waiting: 1, clients: 1),
             "resume lastSeq=12 mode=replay frames=3 waiting=1 clients=1"),
            (.answer(sent: "toolu_A", open: "toolu_B", code: "prompt_changed"),
             "answer sent=toolu_A open=toolu_B code=prompt_changed"),
            (.answer(sent: "toolu_A", open: nil, code: "not_waiting"),
             "answer sent=toolu_A open=none code=not_waiting"),
            (.answer(sent: "toolu_A", open: "toolu_A", code: nil),
             "answer sent=toolu_A open=toolu_A code=ok"),
        ]
        for (event, expected) in cases {
            XCTAssertEqual(
                PromptLifecycleRecord(session: id, event: event).summary,
                "prompt session=3F2504E0-4F89-11D3-9A0C-0305E82C3301 \(expected)"
            )
        }
    }

    /// A resume is about a connection, not a session, and says so rather than inventing an id.
    func testARecordWithNoSessionSaysSoRatherThanOmittingTheField() {
        XCTAssertEqual(
            PromptLifecycleRecord(
                session: nil,
                event: .resumed(lastSeq: 0, mode: "snapshot-initial", frames: 1,
                                waiting: 0, clients: 1)
            ).summary,
            "prompt session=- resume lastSeq=0 mode=snapshot-initial frames=1 waiting=0 clients=1"
        )
    }

    /// The option labels and the tool summary are the user's own words: they go to the file,
    /// never to the unified log.
    func testTheDialogsOwnWordsAreInTheDetailAndNotTheSummary() throws {
        let (recorder, transcript, _) = standUp()
        transcript.lines = [SourceLine(offset: 0, text: bashLine("toolu_BASH"))]

        report(.waiting)

        let opened = try XCTUnwrap(recorder.records.first)
        XCTAssertEqual(opened.detail, "rm -rf build")
        XCTAssertFalse(opened.summary.contains("rm -rf build"))
    }

    // MARK: - The file

    /// Appends, never replaces: the history already in the file is worth more than any one
    /// record, and this is the only durable copy once the unified log's ring has turned over.
    func testTheFileSinkAppendsOneTimestampedLinePerRecordAndKeepsWhatWasThere() throws {
        let url = projectsRoot.appendingPathComponent("prompt.log")
        try "already here\n".write(to: url, atomically: true, encoding: .utf8)
        let id = UUID()

        PromptLifecycleLog.write(
            PromptLifecycleRecord(
                session: id,
                event: .opened(call: "toolu_A", agent: "claude",
                               kind: .permission(tool: "Bash")),
                detail: "rm -rf build"
            ),
            to: url
        )
        PromptLifecycleLog.write(
            PromptLifecycleRecord(
                session: id, event: .closed(call: "toolu_A", reason: .activity("idle"))
            ),
            to: url
        )

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "already here")
        XCTAssertTrue(lines[1].hasSuffix(
            "prompt session=\(id.uuidString) opened call=toolu_A agent=claude "
                + #"kind=permission tool=Bash detail="rm -rf build""#
        ), lines[1])
        XCTAssertTrue(lines[2].hasSuffix(
            "prompt session=\(id.uuidString) closed call=toolu_A reason=activity-idle"
        ), lines[2])
        // A timestamp with an offset on it, so a record can be lined up against the unified
        // log without arithmetic.
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(lines[1].prefix(19)) + "Z"))
    }

    /// One line per record, whatever the detail contains. A `grep` over this file has to
    /// return whole records, and a question can carry a newline.
    func testADetailCarryingNewlinesStaysOnOneLine() throws {
        let url = projectsRoot.appendingPathComponent("prompt.log")

        PromptLifecycleLog.write(
            PromptLifecycleRecord(
                session: UUID(),
                event: .opened(call: "toolu_A", agent: "claude",
                               kind: .question(options: [2])),
                detail: "line one\nline \"two\""
            ),
            to: url
        )

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertTrue(text.contains(#"detail="line one line 'two'""#), text)
    }

    /// A path that cannot be written is not a reason to behave differently. The whole point is
    /// that logging never becomes a failure mode of the thing it is watching.
    func testAnUnwritableDestinationIsSwallowed() {
        let url = URL(fileURLWithPath: "/dev/null/nope/prompt.log")
        PromptLifecycleLog.write(
            PromptLifecycleRecord(
                session: UUID(), event: .closed(call: "toolu_A", reason: .sessionRemoved)
            ),
            to: url
        )
    }
}
