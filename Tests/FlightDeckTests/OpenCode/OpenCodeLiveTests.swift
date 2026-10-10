import IntakeKit
import FleetKit
import XCTest
@testable import FlightDeck

/// **The adapter against a real `opencode serve`.** Skipped unless `FLIGHTDECK_OPENCODE_LIVE`
/// is set; run it with `scripts/test-opencode-live.sh`, which starts the scripted model
/// (`scripts/opencodeprobe/fake_llm.py`), points OpenCode's config at it in a throwaway
/// `XDG_CONFIG_HOME`, and runs only this class.
///
/// Everything here is the production object, not a stand-in: `OpenCodeServer` probes and
/// spawns the binary, `OpenCodeRuntime` reads the real event stream, `OpenCodeMirror` reads the
/// real database, and the text channel, prompt reader and responder are the ones the store
/// uses. Only the model is scripted, so every turn does exactly one known thing.
@MainActor
final class OpenCodeLiveTests: XCTestCase {
    private var home: URL!
    private var root: URL!
    private var project: URL!
    private var events: [AgentEvent] = []

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["FLIGHTDECK_OPENCODE_LIVE"] != nil else {
            throw XCTSkip("set FLIGHTDECK_OPENCODE_LIVE (scripts/test-opencode-live.sh) to run against a real opencode")
        }
        root = OpenCodeFixtures.temporaryDirectory()
        home = root.appendingPathComponent("data", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("print(1)\n".utf8).write(to: project.appendingPathComponent("hello.py"))
    }

    private func wait(
        _ what: String, timeout: TimeInterval = 45, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            // A FAILURE, not a skip: a live run that times out has found something wrong, and
            // a skip would report it as "not run".
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what); events so far: \(events)")
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private struct TimedOut: Error {}

    private func mirrorText(_ binding: AgentBinding) -> String {
        binding.transcriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private func openPrompt(_ binding: AgentBinding) -> OpenPrompt? {
        let lines = mirrorText(binding).split(separator: "\n").enumerated()
            .map { SourceLine(offset: $0.offset, text: String($0.element)) }
        return OpenCodeOpenPromptReader().openPrompt(inTranscriptTail: lines, activity: .waiting)
    }

    /// Runs one headless planning command exactly as `RoundExecutor` builds it — argv from
    /// `HeadlessCommand.build`, environment from `HeadlessCommand.environment` — against the real
    /// `opencode run`, billed to this test's account home.
    private func headless(_ request: HeadlessRequest) async throws -> (stdout: Data, stderr: String) {
        let command = try HeadlessCommand.build(request)
        let executable = try await OpenCodeServer.locate()
        let environment = HeadlessCommand.environment(
            for: command, base: ProcessInfo.processInfo.environment,
            account: AgentAccountRef(id: "live", home: home)
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = command.arguments
        process.environment = environment
        process.currentDirectoryURL = request.cwd
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        let stderr = await Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        return (stdout, String(decoding: stderr, as: UTF8.self))
    }

    private func planningRequest(_ prompt: String, cwd: URL, access: HeadlessAccess = .readOnly,
                                 resume: String? = nil) -> HeadlessRequest {
        HeadlessRequest(agent: .opencode, model: "fake/fake-model", effort: "", cwd: cwd, readableDirs: [],
                        prompt: prompt, schemaFile: cwd.appendingPathComponent("schema.json"),
                        schemaJSON: #"{"type":"object","properties":{"ok":{"type":"boolean"}}}"#,
                        resumeSessionID: resume, access: access)
    }

    /// **Headless planning against the real `opencode run`:** the read-only seat answers, can
    /// resume its own session, and has no tool that writes; the integrator writes inside its
    /// work dir and is refused outside it.
    func testHeadlessPlanningSeatsAgainstRealOpenCode() async throws {
        // A read-only seat's structured answer, and its session.
        let answer = try await headless(planningRequest("ANSWER_JSON please", cwd: project))
        let parsed = try HeadlessOutput.parse(.opencode, stdout: answer.stdout)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: parsed.structured) as? [String: Bool], ["ok": true],
                       "stderr: \(answer.stderr)")
        XCTAssertTrue(parsed.sessionID.hasPrefix("ses_"))

        // The repair path: the same session, resumed.
        let resumed = try await headless(planningRequest("ANSWER_JSON again", cwd: project, resume: parsed.sessionID))
        XCTAssertEqual(try HeadlessOutput.parse(.opencode, stdout: resumed.stdout).sessionID, parsed.sessionID)

        // Read-only means the model is OFFERED nothing that writes or runs.
        let tools = try await headless(planningRequest("SHOW_TOOLS", cwd: project))
        let listed = OpenCodeProfile.parse(tools.stdout).answer ?? ""
        XCTAssertTrue(listed.hasPrefix("TOOLS="), listed)
        let offered = Set(listed.dropFirst("TOOLS=".count).split(separator: ",").map(String.init))
        XCTAssertTrue(offered.isSubset(of: ["read", "grep", "glob", "list"]), "offered: \(offered)")
        XCTAssertTrue(offered.contains("read"))
        _ = try await headless(planningRequest("WRITE_FILE", cwd: project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("PWNED.md").path))

        // The integrator: a write inside its work dir lands, one outside is denied.
        let work = root.appendingPathComponent("intake/work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        _ = try await headless(planningRequest("WRITE_FILE", cwd: work, access: .writeInWork(work)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("PWNED.md").path),
                      "the integrator's edit rule did not match its own work dir")
        _ = try await headless(planningRequest("WRITE_OUTSIDE", cwd: work, access: .writeInWork(work)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("intake/OUTSIDE.md").path),
                       "the integrator wrote outside its work dir")
    }

    func testTheWholeAdapterAgainstARealServer() async throws {
        // 1. Spawn, with a password; the database appears.
        let server = OpenCodeServer(home: home, root: root.appendingPathComponent("servers"))
        // The server is spawned detached — it is designed to outlive its parent — so a run that
        // fails part-way must still take it down.
        addTeardownBlock { @MainActor in server.stop() }
        do {
            try await server.start()
        } catch {
            print("LIVE-DIAG start failed: \(String(reflecting: error))")
            throw error
        }
        let endpoint = try XCTUnwrap(server.endpoint)
        let healthy = await OpenCodeServer.isHealthy(endpoint)
        XCTAssertTrue(healthy)
        let wrongPassword = await OpenCodeServer.isHealthy(OpenCodeEndpoint(url: endpoint.url, password: "nope"))
        XCTAssertFalse(wrongPassword, "the server must refuse a client without its password")
        XCTAssertNotNil(server.databaseURL)

        var adapter = OpenCodeAdapter(server: server)
        adapter.mirrorRoot = root.appendingPathComponent("mirror")
        let runtime = OpenCodeRuntime(server: server)

        // 2. Identity: a session is created with the tab's title and bound by derived id.
        let session = Session(title: "session 1", workingDirectory: project.path, agent: .opencode)
        let binding = try await adapter.prepare(for: session, options: .opencode(OpenCodeOptions()))
        let sessionID = try XCTUnwrap(adapter.sessionID(of: binding))
        XCTAssertEqual(binding.conversationID, OpenCodeIdentity.conversationID(forSession: sessionID))
        let token = runtime.attach(binding, for: UUID()) { [weak self] in self?.events.append($0) }
        var attached = true
        defer { if attached { runtime.detach(token) } }
        let target = AgentTarget(adapter: adapter, location: AgentLocation(workingDirectory: project.path, binding: binding))

        // 3. A message through the real text channel: nothing typed, one turn, mirrored.
        let spy = SpyInjector()
        var delivered: Bool?
        XCTAssertTrue(OpenCodeTextChannel().submit(
            "hi there", into: TargetedInjector(base: spy, target: target),
            settle: { $0() }, stillWanted: { true }, onFinished: { delivered = $0 }
        ))
        try await wait("the first turn to end") { events.contains(.turnEnded) }
        XCTAssertEqual(delivered, true)
        XCTAssertEqual(spy.events, [])
        try await wait("the reply in the mirror") { mirrorText(binding).contains("Hello from the fake model.") }
        XCTAssertTrue(mirrorText(binding).contains("hi there"), "the user's own message is mirrored with its text")

        // 4. A permission request: the tab waits, the mirror names the request, and the
        //    responder answers it by id.
        events = []
        try await adapter.client().prompt(sessionID, text: "RUN_LS please", directory: project.path)
        try await wait("the permission request") { events.contains(.activity(.waiting)) }
        try await wait("the request in the mirror") { openPrompt(binding) != nil }
        let permission = try XCTUnwrap(openPrompt(binding))
        guard case .permission(let requestID, let tool, _) = permission else { return XCTFail("\(permission)") }
        XCTAssertTrue(requestID.hasPrefix("per_"))
        XCTAssertEqual(tool, "bash")
        XCTAssertTrue(OpenCodePromptResponder().answer(permission, with: .allow, for: target))
        try await wait("the approved turn to end") { events.contains(.turnEnded) }
        // The call and its result, paired — not the result's text: OpenCode's own bash tool
        // intermittently reports `(no output)` for a fast `ls` (seen in live runs and in the
        // captured `permission-dialog` screen), so asserting on `hello.py` tested OpenCode.
        try await wait("the tool call and its result in the mirror") {
            let items = mirrorText(binding).split(separator: "\n").enumerated()
                .flatMap { OpenCodeTimelineMapper.items(inLine: String($0.element), at: $0.offset) }
            let calls = Set(items.filter { $0.kind == .toolCall && $0.body.tool == "bash" }.compactMap(\.body.callID))
            return items.contains { $0.kind == .toolResult && calls.contains($0.body.callID ?? "") && !($0.body.callID ?? "").hasPrefix("per_") }
        }
        XCTAssertNil(openPrompt(binding), "the resolved request is no longer open")

        // 5. A question, answered by label.
        events = []
        try await adapter.client().prompt(sessionID, text: "ASK_QUESTION now", directory: project.path)
        try await wait("the question") { openPrompt(binding) != nil }
        let question = try XCTUnwrap(openPrompt(binding))
        guard case .question(_, let questions) = question else { return XCTFail("\(question)") }
        XCTAssertEqual(questions.first?.options.map(\.label), ["Yes", "No"])
        XCTAssertTrue(OpenCodePromptResponder().answer(question, with: .option(index: 0, label: "Yes"), for: target))
        try await wait("the answered turn to end") { events.contains(.turnEnded) }
        XCTAssertTrue(mirrorText(binding).contains(#""outcome":"answered""#))

        // 6. Rename over the wire comes back as the tab's title.
        events = []
        try await adapter.rename(binding, to: "renamed by flight deck")
        try await wait("the title event") { events.contains(.title("renamed by flight deck")) }

        // 7. Abort mid-turn: an abort, then the turn ending — never an API error.
        events = []
        try await adapter.client().prompt(sessionID, text: "SLOW please", directory: project.path)
        try await wait("the slow turn to start") { events.contains(.activity(.busy)) }
        // Mid-stream, not merely busy: an abort before the model's first chunk ends the turn
        // with no `MessageAbortedError` at all (see `OpenCodeSignal.turnAborted`). The fake
        // model ticks every 0.5 s.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try await adapter.client().abort(sessionID, directory: project.path)
        try await wait("the abort") { events.contains(.turnAborted) }
        try await wait("the aborted turn to end") { events.contains(.turnEnded) }
        XCTAssertFalse(events.contains { if case .apiError(.some) = $0 { true } else { false } })

        // 8. A model that refuses: an APIError the retry ladder may NOT act on.
        events = []
        try await adapter.client().prompt(sessionID, text: "FAIL_FOREVER", directory: project.path)
        try await wait("the API error") {
            events.contains { if case .apiError(.some) = $0 { true } else { false } }
        }
        guard case .apiError(let error?) = events.first(where: { if case .apiError(.some) = $0 { true } else { false } })
        else { return XCTFail() }
        XCTAssertEqual(error.kind, "APIError")
        XCTAssertFalse(OpenCodeTurnRecovery().retries(error), "a 400 is not transient")

        // 9. Rebind keeps a session that exists.
        let restored = Session(title: "renamed by flight deck", workingDirectory: project.path,
                               pinnedConversationID: binding.conversationID, agent: .opencode,
                               transcriptPath: binding.transcriptURL?.path)
        let rebound = try await adapter.rebind(for: restored, options: .opencode(OpenCodeOptions()))
        XCTAssertEqual(rebound.conversationID, binding.conversationID)
        let title = await adapter.title(of: binding, directory: project.path)
        XCTAssertEqual(title, "renamed by flight deck")

        // 10. ⌘K finds the conversation, under the derived id and its own name.
        let corpus = OpenCodeSearchCorpus(mirrorRoot: root.appendingPathComponent("mirror-search"))
        let refs = corpus.transcripts(
            forProjects: [project.path],
            accounts: [AgentAccount(agent: .opencode, displayName: "test", home: home)]
        )
        let ref = try XCTUnwrap(refs.first { $0.conversationID == binding.conversationID.uuidString.lowercased() })
        XCTAssertEqual(ref.indexedName, "renamed by flight deck")
        let lines = try String(contentsOf: ref.url, encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(lines.contains { corpus.indexedMessages(inLine: String($0), conversationID: "", at: 0).first?.text == "hi there" })

        // 11. A second Flight Deck adopts the running server instead of spawning another.
        let second = OpenCodeServer(home: home, root: root.appendingPathComponent("servers"))
        try await second.start()
        XCTAssertEqual(second.endpoint, endpoint)

        // 12. Stopping it takes it down — with the last tab gone first, as in production.
        runtime.detach(token)
        attached = false
        server.stop()
        var stillUp = true
        for _ in 0..<50 where stillUp {
            try await Task.sleep(nanoseconds: 200_000_000)
            stillUp = await OpenCodeServer.isHealthy(endpoint)
        }
        XCTAssertFalse(stillUp, "the server still answered 10 s after stop()")
    }
}
