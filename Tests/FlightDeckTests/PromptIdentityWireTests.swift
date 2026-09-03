import FleetKit
import XCTest
@testable import FlightDeck

/// What a client is told about *which* dialog a tab is blocked on.
///
/// **The case the wire could not previously express.** `activity` was the only thing a client
/// was ever told about a dialog, so one prompt superseded by another while the session stayed
/// `waiting` moved nothing at all: same activity, often the same `waitingFor`, no event, and a
/// phone left drawing — and offering Allow for — a dialog the Mac had already left. Every test
/// here is about that tick, or about the two things that must not change because of it: a
/// quiet fleet stays quiet, and an idle one reads no transcripts.
///
/// Behaviour, unlike `PromptLifecycleTests` next door: that file asserts what the *log*
/// records and is explicit that nothing in it may become a test of what the fleet does. This
/// is the other half.
@MainActor
final class PromptIdentityWireTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    /// The transcript the tail seam serves, rewritten between phases of one test.
    ///
    /// `PromptService.tail` is `@Sendable`, so a captured `var` cannot be written from inside
    /// one; every call arrives on the main actor, inline from `commitStatuses`, which is what
    /// `@unchecked` records here — the same arrangement `PromptLifecycleTests` uses.
    private final class Transcript: @unchecked Sendable {
        var lines: [SourceLine] = []
        var reads = 0
    }

    /// Everything one fixture holds onto. The replicator is kept alive for its drift check —
    /// it is the assertion that a store field moving without its event is a test failure, and
    /// this feature adds exactly such a field.
    private struct Fixture {
        let store: SessionStore
        let replicator: FleetReplicator
        /// Held, not merely built. `openPromptCallReader` captures this weakly — `FleetService`
        /// owns the one real instance and a strong capture there would be a cycle through the
        /// store — so a fixture that let it go out of scope would silently report no dialogs
        /// and every assertion below would pass for the wrong reason.
        let prompts: PromptService
        let transcript: Transcript
        let session: UUID
        let sink: Sink
    }

    /// What actually went out, in order. Read off `FleetReplicator.onEvents` — the same hook
    /// `FleetService` broadcasts from — so "was a frame sent" is answered by the thing that
    /// sends them rather than by a store field.
    private final class Sink {
        var events: [FleetEvent] = []
    }

    private var fixture: Fixture?
    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        fixture = nil
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    // MARK: - Fixtures

    private func askLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"AskUserQuestion","input":{"questions":[{"question":"Which?",\
        "multiSelect":false,"options":[{"label":"Rust"},{"label":"Go"}]}]}}]}}
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

    /// A claude tab with a status registry behind it, the same `PromptService` wired into the
    /// store's push seam that an inbound answer would be judged against, and a replicator
    /// reporting what goes on the wire.
    ///
    /// `FleetService` builds this pairing in production; it is assembled by hand here so a
    /// test needs no socket, and so the seam under test is visibly the one being exercised
    /// rather than a side effect of standing a whole service up.
    @discardableResult
    private func standUp() -> Fixture {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let transcript = Transcript()
        let prompts = PromptService(store: store)
        prompts.lifecycleSink = { _ in }
        prompts.tail = { _, _ in
            transcript.reads += 1
            return transcript.lines
        }
        store.openPromptCallReader = { [weak prompts] session in
            guard case .success(let open) = prompts?.pushedOpenPrompt(inSession: session)
            else { return nil }
            return open.callID
        }
        let session = store.newSession(in: tmp)
        let replicator = attachedReplicator(to: store)
        let sink = Sink()
        replicator.onEvents = { batch in sink.events.append(contentsOf: batch.map(\.event)) }
        let fixture = Fixture(store: store, replicator: replicator, prompts: prompts,
                              transcript: transcript, session: session.id, sink: sink)
        self.fixture = fixture
        return fixture
    }

    /// One registry tick, exactly as `SessionStatusWatcher` delivers one. `waitingFor` is a
    /// fixed string rather than a parameter, so two `waiting` ticks produce a byte-identical
    /// `SessionStatus` — which is the premise of the headline test below.
    private func report(_ fixture: Fixture, _ activity: SessionActivity) {
        guard let session = fixture.store.repos.flatMap(\.sessions).first else {
            return XCTFail("the fixture must have exactly one tab")
        }
        fixture.store.applyRegistry([1: .init(
            pid: 1, sessionID: session.pinnedConversationID, activity: activity,
            waitingFor: activity == .waiting ? "permission" : nil,
            startedAt: 1, cwd: tmp.path, procStart: "start-a"
        )])
    }

    // MARK: - The tick nothing used to be sent for

    /// **The headline.** claude answers one dialog and raises the next; the session never
    /// leaves `waiting` and the registry reports a byte-identical status, so before this field
    /// existed `commitStatuses` returned at its guard and not one frame left the machine. The
    /// assertion is that an event exists at all, and that it names the new call.
    func testASupersededDialogIsAWireChangeThoughTheStatusIsIdentical() {
        let f = standUp()
        f.transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        report(f, .waiting)
        f.sink.events.removeAll()

        f.transcript.lines = [
            SourceLine(offset: 0, text: askLine("toolu_A")),
            SourceLine(offset: 1, text: resultLine("toolu_A")),
            SourceLine(offset: 2, text: bashLine("toolu_B")),
        ]
        // The same tick, deliberately: same activity, same reason, same subagent count. The
        // only thing that moved is which dialog is on screen.
        report(f, .waiting)

        XCTAssertEqual(f.sink.events, [
            .activityChanged(
                id: f.session, activity: "waiting", waitingFor: "permission", subagentCount: 0,
                hasBackgroundWork: false, openPromptCall: .call("toolu_B")
            ),
        ])
    }

    /// The other direction of the same failure: the dialog was answered at the keyboard and
    /// claude has not moved off `waiting` yet, so this Mac can name nothing. A client told
    /// nothing keeps its card and every tap on it comes back `prompt_changed`; `.noPrompt` is
    /// this Mac saying it looked.
    func testLosingTheDialogWhileStillWaitingPushesNoPrompt() {
        let f = standUp()
        f.transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        report(f, .waiting)
        f.sink.events.removeAll()

        f.transcript.lines = [
            SourceLine(offset: 0, text: askLine("toolu_A")),
            SourceLine(offset: 1, text: resultLine("toolu_A")),
        ]
        report(f, .waiting)

        XCTAssertEqual(f.sink.events, [
            .activityChanged(
                id: f.session, activity: "waiting", waitingFor: "permission", subagentCount: 0,
                hasBackgroundWork: false, openPromptCall: .noPrompt
            ),
        ])
    }

    /// **A client applying that event stops naming the dialog it was drawing.** The fold is
    /// what a phone actually runs against the frame — `SnapshotApplication` — so this is the
    /// receiving half of the headline, asserted over the same events that were sent.
    func testAClientApplyingTheChangeStopsNamingTheOldDialog() {
        let f = standUp()
        f.transcript.lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        report(f, .waiting)
        var client = f.replicator.snapshot().fleet
        XCTAssertEqual(client.projects.flatMap(\.sessions).first?.openPromptCall,
                       .call("toolu_A"), "the premise: the client is drawing A")
        f.sink.events.removeAll()

        f.transcript.lines = [
            SourceLine(offset: 0, text: askLine("toolu_A")),
            SourceLine(offset: 1, text: resultLine("toolu_A")),
            SourceLine(offset: 2, text: bashLine("toolu_B")),
        ]
        report(f, .waiting)
        for event in f.sink.events { client.apply(event) }

        let session = client.projects.flatMap(\.sessions).first
        XCTAssertEqual(session?.id, f.session)
        XCTAssertEqual(session?.openPromptCall, .call("toolu_B"))
        XCTAssertEqual(session?.activity, "waiting", "still blocked — only the dialog moved")
    }

    // MARK: - What must not change

    /// A poll that finds the same dialog still up emits nothing. The clock ticks twice a
    /// second while a dialog is open, so an axis that reported "still A" as news would put a
    /// frame on a possibly-cellular link every 500 ms for as long as a question went unread.
    func testARepeatedTickWithTheSameDialogEmitsNothing() {
        let f = standUp()
        f.transcript.lines = [SourceLine(offset: 0, text: bashLine("toolu_A"))]
        report(f, .waiting)
        f.sink.events.removeAll()

        report(f, .waiting)
        report(f, .waiting)

        XCTAssertEqual(f.sink.events, [])
    }

    /// An idle or busy fleet reads no transcript at all. The derivation runs inside
    /// `commitStatuses`, which runs on every registry poll — so without the `waiting` gate
    /// this would be a tail read per tab, twice a second, for the life of the app.
    func testNoTranscriptIsReadWhileNothingIsBlocked() {
        let f = standUp()

        report(f, .idle)
        report(f, .busy)
        report(f, .idle)
        XCTAssertEqual(f.transcript.reads, 0)

        // And a blocked tab does read, so the assertion above cannot pass by a fixture that
        // was never wired up in the first place.
        f.transcript.lines = [SourceLine(offset: 0, text: bashLine("toolu_A"))]
        report(f, .waiting)
        XCTAssertEqual(f.transcript.reads, 1)
    }

    /// A tab that goes back to work stops naming a dialog, and says so in the same event that
    /// carries the activity. Folding an event that omitted this would leave a client holding a
    /// call id nothing would ever retire.
    func testLeavingWaitingPushesNoPrompt() {
        let f = standUp()
        f.transcript.lines = [SourceLine(offset: 0, text: bashLine("toolu_A"))]
        report(f, .waiting)
        f.sink.events.removeAll()

        report(f, .busy)

        XCTAssertEqual(f.sink.events, [
            .activityChanged(
                id: f.session, activity: "busy", waitingFor: nil, subagentCount: 0,
                hasBackgroundWork: false, openPromptCall: .noPrompt
            ),
        ])
    }
}
