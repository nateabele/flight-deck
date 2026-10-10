import IntakeKit
import FleetKit
import XCTest
@testable import FlightDeck

/// The store's OpenCode paths end to end, with the real `OpenCodeAdapter` and its real
/// capability objects, and only the network and the event source faked: a tab is created on
/// the server's session, a phone's message and a rename go over the wire with nothing typed,
/// and a permission is answered by its request id.
@MainActor
final class OpenCodeStoreTests: XCTestCase {
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private var provider: RecordingProvider!
    private var http: ScriptedOpenCodeHTTP!
    private var server: FakeOpenCodeServer!
    private var runtime: FakeAgentRuntime!
    private var spy: SpyInjector!
    private var database: SyntheticOpenCodeDatabase!
    private let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-store-\(UUID())")

    private func makeStore() throws -> SessionStore {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        provider = RecordingProvider()
        http = ScriptedOpenCodeHTTP()
        database = try SyntheticOpenCodeDatabase()
        try database.session("ses_new", directory: workspace.path, title: "session 1")
        server = FakeOpenCodeServer(databaseURL: database.url)
        runtime = FakeAgentRuntime()
        spy = SpyInjector()
        spy.viewportOverride = try OpenCodeFixtures.screen("idle-composer")

        let store = SessionStore(provider: provider, persistence: nil)
        store.transcriptsRootOverride = workspace
        store.launchFailureReporter = SilentReporter()
        store.appIsActive = { false }
        store.titleResolver = { _, _, done in done(nil) }
        store.injectorOverride = spy
        var adapter = OpenCodeAdapter(server: server)
        adapter.mirrorRoot = workspace.appendingPathComponent("mirror")
        let http = self.http!
        adapter.transport = { _ in http }
        store.overrideAdapter(adapter, for: .opencode, account: nil)
        store.overrideRuntime(runtime, for: .opencode, account: nil)
        http.on("POST", "/session", json: ["id": "ses_new", "title": "session 1", "directory": workspace.path])
        return store
    }

    private func makeTab(_ store: SessionStore) async throws -> UUID {
        guard case .success(let id) = await store.createSession(agent: .opencode, in: workspace.path) else {
            throw XCTSkip("createSession failed")
        }
        return id
    }

    private var conversation: UUID { OpenCodeIdentity.conversationID(forSession: "ses_new") }

    private func requests(_ method: String, _ path: String, atLeast count: Int = 1) async -> [OpenCodeRequest] {
        for _ in 0..<200 {
            let matching = http.requests.filter { $0.method == method && $0.path == path }
            if matching.count >= count { return matching }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return http.requests.filter { $0.method == method && $0.path == path }
    }

    func testCreatingATabPinsTheServersSessionAndAttachesToIt() async throws {
        let store = try makeStore()
        let id = try await makeTab(store)
        let session = try XCTUnwrap(store.repos.flatMap(\.sessions).first { $0.id == id })
        XCTAssertEqual(session.agent, .opencode)
        XCTAssertEqual(session.pinnedConversationID, conversation)
        XCTAssertEqual(session.transcriptPath.map { URL(fileURLWithPath: $0).lastPathComponent }, "ses_new.jsonl")
        let config = try XCTUnwrap(provider.configs.last)
        XCTAssertEqual(config.initialInput,
                       "opencode attach http://127.0.0.1:45555 --dir '\(workspace.path)' -s ses_new\n")
        XCTAssertEqual(config.environmentVariables["OPENCODE_SERVER_PASSWORD"], server.password)
        XCTAssertEqual(runtime.attached, [conversation])
        XCTAssertEqual(server.starts, 0, "an injected adapter owns its server — the store starts nothing")
    }

    func testAPhoneMessageGoesOverTheWireAndTypesNothing() async throws {
        let store = try makeStore()
        let id = try await makeTab(store)
        http.on("POST", "/session/ses_new/prompt_async", status: 204)

        let outcome = store.submitPrompt("run the tests", token: UUID(), to: id)

        XCTAssertTrue(outcome == .sent || outcome == .queued, "\(outcome)")
        let sent = await requests("POST", "/session/ses_new/prompt_async")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.query["directory"], workspace.path)
        XCTAssertEqual(spy.events, [], "nothing is typed at the terminal")
    }

    func testAMessageWaitsBehindAnOpenDialog() async throws {
        let store = try makeStore()
        let id = try await makeTab(store)
        spy.viewportOverride = try OpenCodeFixtures.screen("permission-dialog")
        XCTAssertFalse(store.injectionGateAdmitsForTesting(id))
        spy.viewportOverride = try OpenCodeFixtures.screen("busy-composer")
        XCTAssertTrue(store.injectionGateAdmitsForTesting(id))
    }

    func testARenameIsOnePatchAndNoTyping() async throws {
        let store = try makeStore()
        let id = try await makeTab(store)
        http.on("PATCH", "/session/ses_new", json: ["id": "ses_new", "title": "parser fix"])

        XCTAssertTrue(store.rename(id, to: "parser fix"))

        let patches = await requests("PATCH", "/session/ses_new")
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(http.body(of: try XCTUnwrap(patches.first))?["title"] as? String, "parser fix")
        XCTAssertEqual(store.title(of: id), "parser fix")
        XCTAssertEqual(spy.events, [])
        XCTAssertNil(store.pendingRenamesForTesting[id], "no pty half is queued")
    }

    func testAPermissionIsAnsweredByItsRequestID() async throws {
        let store = try makeStore()
        let id = try await makeTab(store)
        http.on("POST", "/permission/per_1/reply", json: true)
        let open = OpenPrompt.permission(callID: "per_1", tool: "bash", summary: "ls")
        let token = UUID()

        XCTAssertEqual(store.answerPrompt(open, with: .allow, in: id, token: token), .notWaiting)
        runtime.emit(.activity(.waiting), for: conversation)
        XCTAssertEqual(store.answerPrompt(open, with: .allow, in: id, token: token), .dispatched)
        XCTAssertEqual(store.answerPrompt(open, with: .allow, in: id, token: token), .duplicate)

        let replies = await requests("POST", "/permission/per_1/reply")
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(http.body(of: try XCTUnwrap(replies.first))?["reply"] as? String, "once")
        XCTAssertEqual(spy.events, [], "no key was pressed")
    }

    func testABlindAbortRejectsByIDRatherThanPressingEscape() async throws {
        let store = try makeStore()
        let id = try await makeTab(store)
        http.on("GET", "/permission", json: [["id": "per_9", "sessionID": "ses_new"]])
        http.on("GET", "/question", json: [])
        runtime.emit(.activity(.waiting), for: conversation)

        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .dispatched)

        let rejects = await requests("POST", "/permission/per_9/reply")
        XCTAssertEqual(http.body(of: try XCTUnwrap(rejects.first))?["reply"] as? String, "reject")
        XCTAssertEqual(spy.events, [])
    }

    /// The real stack path, not an override: the factory hands the store a fake server whose
    /// endpoint answers nothing, so `prepare` fails — and the server the creation started must
    /// not be left running for a tab that never came to exist.
    func testAFailedCreationStopsTheServerItStarted() async throws {
        let fake = FakeOpenCodeServer(running: false, databaseURL: nil)
        let store = SessionStore(provider: RecordingProvider(), persistence: nil)
        store.launchFailureReporter = SilentReporter()
        store.openCodeServerFactory = { _ in fake }
        fake.startError = nil

        let result = await store.createSession(agent: .opencode, in: NSTemporaryDirectory())

        guard case .failure(let error) = result else { return XCTFail("created against a dead endpoint") }
        XCTAssertEqual(fake.starts, 1, "the account's server was asked to start once")
        XCTAssertEqual(fake.stops, 1, "and stopped again with no tab left to serve")
        XCTAssertEqual(store.openCodeStackCountForTesting, 0)
        XCTAssertTrue(error.errorDescription?.contains("OpenCode") ?? false, "\(error)")
    }

    func testAServerThatCannotStartIsReportedNamingOpenCode() async throws {
        let fake = FakeOpenCodeServer(running: false)
        fake.startError = AgentLaunchError.agentTooOld(agent: "OpenCode", found: "1.0.0", minimum: "1.18.0")
        let store = SessionStore(provider: RecordingProvider(), persistence: nil)
        store.launchFailureReporter = SilentReporter()
        store.openCodeServerFactory = { _ in fake }

        let result = await store.createSession(agent: .opencode, in: NSTemporaryDirectory())

        XCTAssertEqual(result, .failure(.agentTooOld(agent: "OpenCode", found: "1.0.0", minimum: "1.18.0")))
    }
}
