import XCTest
import IntakeKit
import FleetKit
@testable import FlightDeck

/// The host is every side effect of a hand-off that touches the outside world: keys typed into a
/// live terminal, `br` and `am`, notifications, the log. These pin the guards that keep those
/// side effects from landing where they do harm — an Escape into an idle draft, an exit command
/// typed into a dialog, a silent "yes" when the user asked to be asked.
@MainActor
final class HandoffHostTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Codex's app-server, scripted just far enough to create a thread so a codex tab exists
    /// without `codex` ever being spawned (same arrangement as AgentTextChannelTests).
    private final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(Self.thread)","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            case "thread/read":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(Self.thread)","name":"t","status":{"type":"idle"},"path":"/r/x.jsonl","cwd":"/w/a"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
        static let thread = "01a01269-baa6-7493-8d15-8fa21bcb602b"
    }

    private struct CodexTabUnavailable: Error {}

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fd-handoff-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A live tab with a spy that can be typed into, `injectionSettle` run inline so what the
    /// spy recorded is what was typed. Without the inline settle and the stub surface provider
    /// `submitPrompt` can answer `.queued` having typed nothing, and a retire test that accepts
    /// `.queued` passes while the exit command is never sent (Task 14 ruling 1).
    private func storeWithTab(_ status: SessionStatus, agent: AgentID = .claude) async throws -> (SessionStore, UUID, SpyInjector) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = root
        store.codexIndexURLOverride = root.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let id: UUID
        if agent == .codex {
            store.overrideAdapter(
                CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport()), rolloutExists: { _ in true }),
                for: .codex, account: nil)
            guard case .success(let created) = await store.createSession(agent: .codex, in: root.path) else {
                XCTFail("codex tab creation must succeed against a scripted transport")
                throw CodexTabUnavailable()
            }
            id = created
            // Codex's composer is recognised by its own status line, byte-stable through a turn.
            spy.viewportOverride = """
            › Ask Codex to do anything

              gpt-5.6-sol default · /tmp/work
            """
        } else {
            id = store.newSession(in: root).id
        }
        store.applyRegistryForTesting([id: status])
        spy.events.removeAll()
        return (store, id, spy)
    }

    func testInterruptOnlyEscapesABusyTurn() async throws {
        let (busy, b, busySpy) = try await storeWithTab(SessionStatus(activity: .busy))
        XCTAssertTrue(busy.interruptTurn(b))
        XCTAssertEqual(busySpy.events, [.escape])

        let (idle, i, idleSpy) = try await storeWithTab(SessionStatus(activity: .idle))
        XCTAssertFalse(idle.interruptTurn(i), "Escape on an idle composer clears the user's draft")
        XCTAssertEqual(idleSpy.events, [])
    }

    /// Ruling 2 (M3): `activity` is lifted to busy while a background subagent runs, so an
    /// agent idle at its composer would take the deadline Escape and lose its draft. The gate
    /// reads what the agent itself reported.
    func testASubagentKeepingTheTabBusyIsNotInterrupted() async throws {
        let (store, id, spy) = try await storeWithTab(SessionStatus(activity: .busy, agentActivity: .idle))
        XCTAssertFalse(store.interruptTurn(id), "the agent is idle at its composer; only a subagent is running")
        XCTAssertEqual(spy.events, [])
    }

    func testADialogIsEscapedOnlyWhenAsked() async throws {
        let (store, id, spy) = try await storeWithTab(SessionStatus(activity: .waiting))
        XCTAssertFalse(store.interruptTurn(id), "Escape in a dialog is a denial, not an interrupt")
        XCTAssertEqual(spy.events, [])
        XCTAssertTrue(store.interruptTurn(id, includingDialog: true))
        XCTAssertEqual(spy.events, [.escape])
    }

    func testExitCommands() {
        XCTAssertEqual(AgentID.claude.exitCommand, "/exit")
        XCTAssertEqual(AgentID.codex.exitCommand, "/quit")
    }

    /// Ruling 1 (M2): assert the exact keys, not the dispatch result.
    func testRetiringAnIdleClaudeAgentTypesExitAndNeverEscapes() async throws {
        let (store, id, spy) = try await storeWithTab(SessionStatus(activity: .idle))
        let dispatch = store.retireAgent(id)
        XCTAssertEqual(dispatch, .sent)
        XCTAssertEqual(spy.sent, ["/exit"])
        XCTAssertFalse(spy.events.contains(.escape), "\(spy.events)")
        XCTAssertEqual(spy.events.last, .ret)
    }

    func testRetiringAnAgentInADialogEscapesThenTypesExit() async throws {
        let (store, id, spy) = try await storeWithTab(SessionStatus(activity: .waiting))
        // The screen is the dialog, not the composer: the exit command must not be typed into it.
        spy.viewportOverride = """
        Do you want to proceed?
        ❯ 1. Yes
          2. No
        """
        _ = store.retireAgent(id)
        XCTAssertEqual(spy.events, [.escape], "Escape first, and nothing typed into the dialog")
        // Escape dismissed it: the composer is back and the queued exit command goes out after.
        spy.viewportOverride = nil
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        store.flushPromptQueueForTesting()
        XCTAssertEqual(spy.events.first, .escape)
        XCTAssertEqual(spy.sent, ["/exit"])
    }

    func testRetiringACodexAgentTypesQuit() async throws {
        let (store, id, spy) = try await storeWithTab(SessionStatus(activity: .idle), agent: .codex)
        let dispatch = store.retireAgent(id)
        XCTAssertEqual(dispatch, .sent)
        XCTAssertEqual(spy.sent, ["/quit"])
        XCTAssertFalse(spy.events.contains(.escape))
    }

    func testStopAgentReportsUndeliveredExit() async throws {
        let (store, _, _) = try await storeWithTab(SessionStatus(activity: .idle))
        let host = StoreHandoffHost(store: store, logURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.jsonl"))
        let gone = await host.stopAgent(SessionRef(id: UUID(), agentName: nil))
        XCTAssertFalse(gone, "no such tab: the exit command went nowhere")
    }

    func testStopAgentReportsDeliveredExit() async throws {
        let (store, id, spy) = try await storeWithTab(SessionStatus(activity: .idle))
        let host = StoreHandoffHost(store: store, logURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.jsonl"))
        let ok = await host.stopAgent(SessionRef(id: id, agentName: nil))
        XCTAssertTrue(ok)
        XCTAssertEqual(spy.sent, ["/exit"])
    }

    func testBrAndAmArgvAndWorkingDirectory() async {
        let runner = UsageRecordingRunner()
        let commands = BrAmHandoffCommands(runner: runner)
        let task = TaskRef(id: "fd-3x9", project: URL(fileURLWithPath: "/p/proj"))
        let reassigned = await commands.reassign(task: task, to: "GreenFox")
        let released = await commands.releaseReservations(of: "BlueLake", project: task.project)
        XCTAssertNil(reassigned); XCTAssertNil(released)
        XCTAssertEqual(runner.calls, [
            .init(executable: "br", args: ["update", "fd-3x9", "--assignee", "GreenFox", "--actor", "flightdeck-handoff"], cwd: "/p/proj"),
            .init(executable: "am", args: ["file_reservations", "release", "/p/proj", "BlueLake"], cwd: "/p/proj"),
        ])
    }

    func testACommandFailureIsAWarningNamingTheCommand() async {
        let runner = UsageRecordingRunner()
        runner.exitCode = 1; runner.stdout = "VALIDATION_FAILED: no such issue\nmore"
        let warning = await BrAmHandoffCommands(runner: runner).reassign(task: TaskRef(id: "fd-1", project: URL(fileURLWithPath: "/p")), to: "GreenFox")
        XCTAssertEqual(warning, "br update fd-1 --assignee GreenFox failed (exit 1): VALIDATION_FAILED: no such issue")
    }

    func testRateLimitedReadsTheFleetsAPIError() async throws {
        let (store, id, _) = try await storeWithTab(SessionStatus(activity: .idle))
        let host = StoreHandoffHost(store: store, logURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.jsonl"))
        let ref = SessionRef(id: id, agentName: nil)
        XCTAssertFalse(host.isRateLimited(ref))
        store.apply(.apiError(SessionAPIError(status: 529, kind: "overloaded")), to: id)
        XCTAssertFalse(host.isRateLimited(ref))
        store.apply(.apiError(SessionAPIError(status: 429, kind: "rate_limit")), to: id)
        XCTAssertTrue(host.isRateLimited(ref))
        XCTAssertEqual(host.activity(of: ref), .idle)
    }

    func testConfirmWithNoSurfaceDeclinesAndSaysSo() async throws {
        let (store, id, _) = try await storeWithTab(SessionStatus(activity: .idle))
        let notifier = UsageSpyNotifier()
        store.notifier = notifier
        let host = StoreHandoffHost(store: store, logURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.jsonl"))
        let request = HandoffRequest(task: TaskRef(id: "fd-1", project: URL(fileURLWithPath: "/p")),
                                     block: ExecutionBlock(kind: "tests", harness: "claude", model: "opus", pool: "claude-default",
                                                           source: AssignmentSource(by: .rule, reason: "r", at: Date())),
                                     oldAgent: "BlueLake", oldSession: SessionRef(id: id, agentName: "BlueLake"),
                                     transcript: nil, reservedFiles: [], fromAccount: UsageRefs.work)
        let ok = await host.confirm(request)
        XCTAssertFalse(ok, "the user asked to be asked; nothing may answer for them")
        XCTAssertEqual(notifier.notes.map(\.title), ["Hand-off needs a confirmation"])
        host.confirmer = { _ in true }
        let accepted = await host.confirm(request)
        XCTAssertTrue(accepted)
    }

    func testRecordAppendsOneJSONLinePerEntry() async throws {
        let (store, _, _) = try await storeWithTab(SessionStatus(activity: .idle))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fd-handoff-\(UUID().uuidString)/handoffs.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = StoreHandoffHost(store: store, logURL: url)
        let entry = HandoffLogEntry(at: Date(timeIntervalSince1970: 1_790_000_000), outcome: .handedOff, task: "fd-1",
                                    oldSession: UUID(), oldAgent: "BlueLake", newSession: UUID(), newAgent: "GreenFox",
                                    fromAccount: "Work", toAccount: "Spare", detail: nil)
        host.record(entry); host.record(entry)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(HandoffLogEntry.self, from: Data(lines[0].utf8)), entry)
    }
}
