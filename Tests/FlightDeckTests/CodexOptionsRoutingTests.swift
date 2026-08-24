import FleetKit
import XCTest
@testable import FlightDeck

/// That what the Codex pane in Preferences writes is what `thread/start` is handed.
///
/// The store used to answer `options(for: .codex, project:)` with a hardcoded
/// `CodexThreadOptions()`, so every control in that pane was inert — a user who chose the
/// `read-only` sandbox silently got codex's default instead, which is a safety expectation
/// the UI was breaking. Claude never had this problem because `ClaudeOptionsPane` binds the
/// claude row in `preferences.agents`, which is exactly what `resolvedOptions(for:project:)`
/// reads.
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
        /// Codex's answers, because this stands in for codex — the store reads both
        /// capabilities off `AgentID`, so a stub that disagreed would describe an agent that
        /// does not exist.
        static let textChannel: AgentTextChannel? = nil
        static let dialogDriver: AgentDialogDriver? = nil
        static let negotiatesIdentity = true
        static let needsRuntimeStart = true
        static let hasStatusRegistry = false
        nonisolated static func sanitizedTitle(_ raw: String) -> String? {
            CodexAdapter.sanitizedTitle(raw)
        }
        nonisolated static func title(fromTranscriptAt url: URL) -> String? {
            CodexAdapter.title(fromTranscriptAt: url)
        }
        nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
            CodexAdapter.timelineItems(inLine: line, at: offset)
        }
        nonisolated static let homeMarkerFile = CodexAdapter.homeMarkerFile
        nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? {
            CodexAdapter.identity(fromHomeData: data)
        }
        static let openPromptReader: AgentOpenPromptReader? = CodexAdapter.openPromptReader
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
        func loginInvocation(for account: AgentAccount) -> LoginInvocation { LoginInvocation(command: "", inject: nil) }
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
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl`: this test creates a codex tab.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let adapter = RecordingCodexAdapter()
        // Filed under the account the tab will actually resolve to. This store HAS
        // preferences, and the accounts migration seeds a built-in account per agent, so the
        // key here is that account's id and not nil — an override filed under nil would not
        // be found, and `createSession` would go and spawn a real `codex app-server`.
        store.overrideAdapter(adapter, for: .codex,
                              account: preferences.resolvedAccountID(for: .codex, in: nil))

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
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let adapter = RecordingCodexAdapter()
        // No preferences on this one, so nothing resolves and nil is the key.
        store.overrideAdapter(adapter, for: .codex, account: nil)

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
