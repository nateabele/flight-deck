import XCTest
@testable import FlightDeck

/// That what the Codex pane in Preferences writes is what `thread/start` is handed.
///
/// The store used to answer `options(for: .codex, project:)` with a hardcoded
/// `CodexThreadOptions()`, so every control in that pane was inert — a user who chose the
/// `read-only` sandbox silently got codex's default instead, which is a safety expectation
/// the UI was breaking. Claude never had this problem because `ClaudeOptionsPane` binds
/// `globalFlags`, which is what `resolvedFlags` reads.
@MainActor
final class CodexOptionsRoutingTests: XCTestCase {
    private final class MemoryPreferences: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Records the options it was prepared with. Stands in for `CodexAdapter` so nothing
    /// spawns and no thread is created.
    private final class RecordingCodexAdapter: AgentAdapter {
        static let id: AgentID = .codex
        private(set) var prepared: [AgentOptions] = []

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            prepared.append(options)
            return AgentBinding(conversationID: UUID(), transcriptURL: nil)
        }

        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }

        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
        }

        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
    }

    private var projectsRoot: URL!

    override func setUpWithError() throws {
        projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func makePreferences(_ options: CodexThreadOptions) -> PreferencesStore {
        let preferences = PreferencesStore(persistence: MemoryPreferences())
        // Looked up by id, not by position: the list's order is the New Session shortcut
        // binding, and a user can reorder it. Same lookup `CodexOptionsForm` writes through.
        guard let index = preferences.preferences.agents.firstIndex(where: { $0.id == .codex })
        else { return preferences }
        preferences.preferences.agents[index].options = .codex(options)
        return preferences
    }

    func testTheCodexPanesSettingsReachThreadStart() async throws {
        let preferences = makePreferences(CodexThreadOptions(
            model: "gpt-5-codex", sandbox: "read-only",
            approvalPolicy: "untrusted", addDirs: ["/w/extra"]
        ))
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        store.projectsRoot = projectsRoot
        store.launchFailureReporter = SilentReporter()
        let adapter = RecordingCodexAdapter()
        store.overrideAdapter(adapter, for: .codex)

        _ = await store.createSession(agent: .codex, in: projectsRoot.path)

        guard case .codex(let used)? = adapter.prepared.last else {
            return XCTFail("codex must be prepared with codex options")
        }
        XCTAssertEqual(used.model, "gpt-5-codex")
        XCTAssertEqual(used.sandbox, "read-only",
                       "a user who picked read-only must not silently get codex's default")
        XCTAssertEqual(used.approvalPolicy, "untrusted")
        XCTAssertEqual(used.addDirs, ["/w/extra"])
    }

    func testAStoreWithNoPreferencesStillLaunchesOnCodexsOwnDefaults() async throws {
        let store = SessionStore(provider: nil, persistence: nil)
        store.projectsRoot = projectsRoot
        store.launchFailureReporter = SilentReporter()
        let adapter = RecordingCodexAdapter()
        store.overrideAdapter(adapter, for: .codex)

        _ = await store.createSession(agent: .codex, in: projectsRoot.path)

        XCTAssertEqual(adapter.prepared.last, .codex(CodexThreadOptions()),
                       "no preferences means send nothing and let config.toml decide")
    }

    /// `addDirs` is not a `ThreadStartParams` field — verified against the schema and by
    /// probing a live app-server, which accepts it and ignores it. The writable roots go
    /// through codex's free-form `config` override instead, which is the same mechanism
    /// `codex -c` uses.
    func testAdditionalDirectoriesBecomeWritableRootsInTheConfigOverride() {
        let params = CodexThreadOptions(sandbox: "workspace-write", addDirs: ["/w/b", "/w/c"])
            .asThreadStartParams(cwd: "/w/a")

        let config = params["config"] as? [String: Any]
        let workspace = config?["sandbox_workspace_write"] as? [String: Any]
        XCTAssertEqual(workspace?["writable_roots"] as? [String], ["/w/b", "/w/c"])
    }

    func testNoAdditionalDirectoriesMeansNoConfigOverrideAtAll() {
        // An empty override would still be an override — send nothing so `config.toml` wins.
        let params = CodexThreadOptions(sandbox: "workspace-write").asThreadStartParams(cwd: "/w/a")
        XCTAssertNil(params["config"])
    }
}
