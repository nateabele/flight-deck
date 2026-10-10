import IntakeKit
import FleetKit
import XCTest
@testable import FlightDeck

/// What a build that predates the later agents sees of the files this build writes. These mirror
/// the OLD types exactly as they decode — a raw-value enum with only `claude` and `codex`, the
/// pre-unify build's — so a test failure here is the "older build wipes every tab" failure,
/// caught before it ships.
private enum OldAgentID: String, Codable { case claude, codex }

private struct OldSnapshot: Decodable {
    struct Entry: Decodable { let id: UUID; var agent: OldAgentID? }
    var sessions: [Entry]
}

private struct OldPreferences: Decodable {
    struct Settings: Decodable {
        let id: OldAgentID
        let options: Options
        struct Options: Decodable { let agent: OldAgentID }
    }
    struct Account: Decodable { let agent: OldAgentID }
    struct Project: Decodable {
        var defaultAgent: OldAgentID?
        var accounts: [OldAgentID: UUID]
        var options: [OldAgentID: Settings.Options]
    }
    var storedAgents: [Settings]?
    var storedAccounts: [Account]?
    var storedProjectSettings: [String: Project]?
}

extension OldAgentID: CodingKeyRepresentable {}

@MainActor
final class AgentForwardCompatibilityTests: XCTestCase {
    private func snapshot() -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.sessions = [
            .init(id: UUID(), title: "a", workingDirectory: "/w", agent: .claude),
            .init(id: UUID(), title: "b", workingDirectory: "/w", agent: .opencode),
            .init(id: UUID(), title: "c", workingDirectory: "/w", agent: .codex),
            .init(id: UUID(), title: "d", workingDirectory: "/w"),
            .init(id: UUID(), title: "e", workingDirectory: "/w", agent: .grok),
        ]
        return snapshot
    }

    func testAnOlderBuildStillReadsEveryOtherTab() throws {
        let original = snapshot()
        // The control: written as-is, an older build cannot read the file AT ALL.
        XCTAssertThrowsError(try JSONDecoder().decode(OldSnapshot.self, from: JSONEncoder().encode(original)))
        let data = try JSONEncoder().encode(original.storedForOlderBuilds())
        let old = try JSONDecoder().decode(OldSnapshot.self, from: data)
        XCTAssertEqual(old.sessions.map(\.id), [original.sessions[0], original.sessions[2], original.sessions[3]].map(\.id))
    }

    /// The side field written by a LATER build may name an agent this build has no case for.
    /// That entry is lost; the file — and every other tab in it — is not.
    func testASideEntryFromALaterBuildCostsOnlyThatEntry() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original.storedForOlderBuilds())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var side = try XCTUnwrap(json["laterAgentSessions"] as? [[String: Any]])
        var future = side[0]
        var entry = try XCTUnwrap(future["value"] as? [String: Any])
        entry["agent"] = "sixth-agent"
        entry["id"] = UUID().uuidString
        future["value"] = entry
        future["index"] = 9
        side.append(future)
        json["laterAgentSessions"] = side
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            .restoringLaterAgents()
        XCTAssertEqual(restored.sessions.map(\.id), original.sessions.map(\.id))
    }

    func testThisBuildRestoresTheTabInPlace() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original.storedForOlderBuilds())
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: data).restoringLaterAgents()
        XCTAssertEqual(restored, original)
    }

    /// The real persistence path, end to end through a file.
    func testTheFilePersistenceWritesTheSafeShape() throws {
        let directory = OpenCodeFixtures.temporaryDirectory()
        let persistence = FileSessionPersistence(directory: directory, legacyDefaults: nil)
        let url = directory.appendingPathComponent("sessions.json")
        persistence.save(snapshot())
        let old = try JSONDecoder().decode(OldSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(old.sessions.count, 3)
        XCTAssertEqual(persistence.load()?.sessions.count, 5)
    }

    private func preferences() -> Preferences {
        var prefs = Preferences()
        prefs.storedAgents = Preferences.defaultAgents + [
            AgentSettings(id: .grok, options: .grok(GrokOptions())),
            AgentSettings(id: .opencode, options: .opencode(OpenCodeOptions(model: "ollama/y"))),
        ]
        // Through the list, as every write is: its setter refreshes the flat mirror an older
        // build reads (`AccountList.legacyAccounts`), filtered by the same set.
        prefs.accounts = [
            AgentAccount(agent: .claude, displayName: "c", home: AgentID.claude.builtInHome),
            AgentAccount(agent: .opencode, displayName: "o", home: AgentID.opencode.builtInHome),
        ]
        let openCodeAccount = UUID()
        prefs.storedProjectSettings = [
            "/w": ProjectSettings(
                defaultAgent: .opencode,
                accounts: [.opencode: .account(openCodeAccount), .grok: .pool(PoolID("grok-default"))],
                options: [.claude: .claude(FlagSet()), .opencode: .opencode(OpenCodeOptions(model: "ollama/x"))]
            ),
            "/v": ProjectSettings(defaultAgent: .codex),
        ]
        return prefs
    }

    func testAnOlderBuildStillReadsEveryOtherPreference() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(OldPreferences.self, from: JSONEncoder().encode(preferences())),
                             "the control: unsplit, an older build loses every preference")
        let data = try JSONEncoder().encode(preferences().storedForOlderBuilds())
        let old = try JSONDecoder().decode(OldPreferences.self, from: data)
        XCTAssertEqual(old.storedAgents?.map(\.id), [.claude, .codex])
        XCTAssertEqual(old.storedAccounts?.map(\.agent), [.claude])
        XCTAssertNil(old.storedProjectSettings?["/w"]?.defaultAgent)
        XCTAssertEqual(old.storedProjectSettings?["/w"]?.options.keys.map(\.self), [.claude])
        XCTAssertEqual(old.storedProjectSettings?["/v"]?.defaultAgent, .codex)
    }

    func testThisBuildRestoresEveryPreference() throws {
        let original = preferences()
        let data = try JSONEncoder().encode(original.storedForOlderBuilds())
        let restored = try JSONDecoder().decode(Preferences.self, from: data).restoringLaterAgents()
        XCTAssertEqual(restored, original)
    }

    func testTheDefaultsPersistenceWritesTheSafeShape() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "fd-forward-compat-\(UUID())"))
        let persistence = UserDefaultsPreferencesPersistence(defaults: defaults)
        let original = preferences()
        persistence.save(original)
        let data = try XCTUnwrap(defaults.data(forKey: "preferences.v1"))
        XCTAssertNoThrow(try JSONDecoder().decode(OldPreferences.self, from: data))
        XCTAssertEqual(persistence.load(), original)
    }
}

@MainActor
final class OpenCodeReviewFixTests: XCTestCase {
    // MARK: Mirror

    /// A step whose server was killed never gets its completion stamp; the next step's
    /// existence settles it, so the mirror is not frozen behind it for good.
    func testAnInterruptedStepDoesNotFreezeTheMirror() throws {
        let db = try SyntheticOpenCodeDatabase()
        try db.session("ses_k", directory: "/w", title: "t")
        try db.message("msg_a", session: "ses_k", created: 1, data: ["role": "user"])
        try db.message("msg_b", session: "ses_k", created: 2, data: ["role": "assistant", "time": ["created": 2]])
        try db.message("msg_c", session: "ses_k", created: 3, data: ["role": "user"])
        try db.message("msg_d", session: "ses_k", created: 4, data: ["role": "assistant", "time": ["completed": 5]])
        let mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_k.jsonl")
        try OpenCodeMirror.sync(sessionID: "ses_k", database: db.url, mirror: mirror)
        let lines = try String(contentsOf: mirror, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
    }

    // MARK: Server state

    /// An intentional stop forgets the port, so the next start cannot adopt the server while it
    /// is still draining.
    func testStopForgetsThePort() throws {
        let root = OpenCodeFixtures.temporaryDirectory()
        let home = root.appendingPathComponent("home")
        let first = OpenCodeServer(home: home, root: root)
        let stateFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        var state = try JSONDecoder().decode(OpenCodeServer.State.self, from: Data(contentsOf: stateFile))
        state.port = 45678
        try JSONEncoder().encode(state).write(to: stateFile)

        let second = OpenCodeServer(home: home, root: root)
        second.stop()

        let after = try JSONDecoder().decode(OpenCodeServer.State.self, from: Data(contentsOf: stateFile))
        XCTAssertNil(after.port)
        XCTAssertEqual(after.password, first.password, "the password survives, for surviving shells")
    }

    func testAPlusInADirectoryIsEncoded() throws {
        let url = try XCTUnwrap(URLSessionOpenCodeHTTP.url(
            for: OpenCodeRequest(method: "GET", path: "/permission", query: ["directory": "/Users/me/C++ & co"]),
            baseURL: URL(string: "http://127.0.0.1:1")!
        ))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:1/permission?directory=/Users/me/C%2B%2B%20%26%20co")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       "/Users/me/C++ & co")
    }

    // MARK: Runtime

    private func runtime(_ http: ScriptedOpenCodeHTTP) -> (OpenCodeRuntime, URL, () -> [AgentEvent], AttachmentToken) {
        let server = FakeOpenCodeServer()
        let runtime = OpenCodeRuntime(server: server, workingDirectory: { _ in "/w" })
        runtime.transport = { _ in http }
        let mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_root.jsonl")
        var events: [AgentEvent] = []
        let token = runtime.attach(
            AgentBinding(conversationID: OpenCodeIdentity.conversationID(forSession: "ses_root"), transcriptURL: mirror),
            for: UUID()
        ) { events.append($0) }
        return (runtime, mirror, { events }, token)
    }

    /// A request raised while Flight Deck was not listening (a relaunch with the server still
    /// running) is found on reconnect: the tab waits and the mirror can name it.
    func testAReconnectFindsARequestRaisedWhileAway() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("GET", "/permission", json: [[
            "id": "per_x", "sessionID": "ses_root", "permission": "bash", "patterns": ["ls"],
            "metadata": ["command": "ls"], "always": [],
        ]])
        http.on("GET", "/question", json: [])
        let (runtime, mirror, events, token) = runtime(http)
        defer { runtime.detach(token) }

        await runtime.reconcileRequestsForTesting()

        XCTAssertEqual(events().last, .activity(.waiting))
        let lines = try String(contentsOf: mirror, encoding: .utf8).split(separator: "\n").map(String.init)
        let open = OpenCodeOpenPromptReader().openPrompt(
            inTranscriptTail: lines.enumerated().map { SourceLine(offset: $0.offset, text: $0.element) },
            activity: .waiting
        )
        XCTAssertEqual(open?.callID, "per_x")

        // Reconciling again logs nothing twice.
        await runtime.reconcileRequestsForTesting()
        XCTAssertEqual(try String(contentsOf: mirror, encoding: .utf8).split(separator: "\n").count, 1)
    }

    /// The reverse: a request the server no longer has is closed, so the tab cannot stay
    /// waiting on a dialog that does not exist.
    func testAReconnectClosesARequestTheServerDropped() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("GET", "/permission", json: [["id": "per_x", "sessionID": "ses_root", "permission": "bash", "patterns": []]])
        http.on("GET", "/question", json: [])
        let (runtime, mirror, _, token) = runtime(http)
        defer { runtime.detach(token) }
        await runtime.reconcileRequestsForTesting()

        http.on("GET", "/permission", json: [])
        await runtime.reconcileRequestsForTesting()

        let lines = try String(contentsOf: mirror, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.last?.contains(#""outcome":"gone""#) ?? false)
        let open = OpenCodeOpenPromptReader().openPrompt(
            inTranscriptTail: lines.enumerated().map { SourceLine(offset: $0.offset, text: $0.element) },
            activity: .waiting
        )
        XCTAssertNil(open)
    }

    /// An unknown child's `asked` and a fast `replied` are applied in arrival order once its
    /// parent is known — not in whichever order two lookups happen to finish.
    func testAnUnknownChildsRequestIsAppliedInOrder() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("GET", "/session/ses_kid", json: ["id": "ses_kid", "parentID": "ses_root"])
        let (runtime, mirror, events, token) = runtime(http)
        defer { runtime.detach(token) }

        runtime.handle(OpenCodeEventBatch(directory: "/w", signals: [
            .prompt(session: "ses_kid", line: #"{"id":"per_k","kind":"permission","permission":"bash","type":"prompt.asked"}"#),
        ]))
        runtime.handle(OpenCodeEventBatch(directory: "/w", signals: [
            .prompt(session: "ses_kid", line: #"{"id":"per_k","outcome":"once","type":"prompt.resolved"}"#),
        ]))
        for _ in 0..<100 where !(events().contains(.activity(.busy))) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events(), [.activity(.waiting), .activity(.busy)])
        let lines = try String(contentsOf: mirror, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("prompt.asked"))
    }
}
