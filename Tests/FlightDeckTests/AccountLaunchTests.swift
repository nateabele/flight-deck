import XCTest
@testable import FlightDeck

/// That a tab actually *runs* as its account, and that a tab whose account is gone does not
/// run at all.
///
/// Everything before this task was bookkeeping — a field on `Session`, a key on a registry,
/// a root for a watcher. This is the file that pins the two facts a user can feel: the shell
/// is handed the variable that binds it to a home, and a login that no longer resolves is
/// refused with a name rather than silently downgraded to somebody else's.
@MainActor
final class AccountLaunchTests: XCTestCase {
    // MARK: - The variable

    func testTheAccountVariableIsMergedIntoTheSessionEnvironment() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.shell.environment = ["FOO": "bar"]
        let account = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        let environment = store.sessionEnvironment(for: account, inherited: [:])
        XCTAssertEqual(environment["FOO"], "bar")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/w")
    }

    /// The account wins over a variable the user typed into the Shell pane: the pane cannot be
    /// allowed to silently repoint a tab at another login.
    func testTheAccountOverridesAHandTypedVariable() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.shell.environment = ["CLAUDE_CONFIG_DIR": "/tmp/typed"]
        let account = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        XCTAssertEqual(store.sessionEnvironment(for: account, inherited: [:])["CLAUDE_CONFIG_DIR"], "/tmp/w")
    }

    /// No account is not the same as a wrong one: a store with nothing to resolve must hand
    /// the shell exactly what it handed it before accounts existed.
    func testNoAccountLeavesTheEnvironmentUntouched() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.shell.environment = ["FOO": "bar"]
        XCTAssertEqual(store.sessionEnvironment(inherited: [:]), ["FOO": "bar"])
    }

    // MARK: - Refusing a login that is gone

    func testAMissingAccountIsReportedRatherThanSubstituted() async {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = []
        preferences.preferences.storedProjectSettings = ["/p": ProjectSettings(accounts: [.claude: UUID()])]
        let store = makeStore(preferences)

        let result = await store.createSession(agent: .claude, in: "/p")
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, .accountMissing("Claude"))
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty,
                      "a tab under the wrong login is worse than no tab")
    }

    /// The codex half, and the ordering that matters: the account is resolved before anything
    /// is negotiated, so a broken login never reaches `prepare` and never spawns an
    /// app-server to prepare against.
    func testABrokenAccountIsRefusedBeforeCodexIsTouched() async {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = []
        preferences.preferences.storedProjectSettings = ["/p": ProjectSettings(accounts: [.codex: UUID()])]
        let store = makeStore(preferences)

        let result = await store.createSession(agent: .codex, in: "/p")
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, .accountMissing("Codex"))
        XCTAssertEqual(store.codexServerRequestsForTesting, 0,
                       "a login that cannot launch must not start an app-server")
        XCTAssertFalse(store.hasCodexStackForTesting)
    }

    /// A home the user moved or deleted. Refused rather than handed to the agent, which would
    /// happily create the directory again and start a logged-out session in it — the wrong
    /// login wearing the right name.
    func testAnAccountWhoseHomeIsGoneIsRefusedRatherThanRecreated() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let work = AgentAccount(agent: .claude, displayName: "Work", home: missing)
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [work]
        let store = makeStore(preferences)

        let result = await store.createSession(agent: .claude, in: "/p")
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, .accountHomeMissing("Work"))
        XCTAssertEqual(error.errorDescription?.contains("Relocate"), true,
                       "the alert has to say what to do about it")
    }

    /// `newSession` has no `Result` to return — it is claude's synchronous path, and 140-odd
    /// call sites treat it as infallible. The refusal therefore reaches the user through the
    /// same reporter `createSession` uses, and the only observable difference is that no tab
    /// appears.
    func testTheSynchronousPathRefusesABrokenAccountThroughTheReporter() {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = []
        preferences.preferences.storedProjectSettings = ["/p": ProjectSettings(accounts: [.claude: UUID()])]
        let store = makeStore(preferences)

        store.newSession(in: URL(fileURLWithPath: "/p", isDirectory: true))

        XCTAssertEqual(reporter.reported, [.accountMissing("Claude")],
                       "a refusal nobody is told about is the silent wrong-login bug again")
        XCTAssertTrue(store.repos.isEmpty, "no tab, and no project to hold one")
    }

    // MARK: - Stamping the account at creation

    /// The stamp itself. Without it every tab created today persists `accountID: nil` — the
    /// built-in home — and the whole feature no-ops for new tabs while every other test still
    /// passes, because `resolvedAccountID` normalises nil to the built-in account and nothing
    /// downstream can tell the difference until the default changes.
    func testANewTabIsStampedWithTheAccountItRunsAs() throws {
        let (preferences, work) = configured(.claude)
        let store = makeStore(preferences)

        let session = store.newSession(in: projectURL)

        XCTAssertEqual(session.accountID, work.id)
        XCTAssertEqual(store.repos.first?.sessions.first?.accountID, work.id,
                       "the filed tab carries it, not just the value handed back")
    }

    /// The project's explicit choice, not merely the top of the list — the stamp has to record
    /// what actually launched, or a later reassignment retroactively rewrites where an
    /// existing tab's conversation is believed to live.
    func testTheStampFollowsTheProjectsChoiceRatherThanTheDefault() {
        let (preferences, top) = configured(.claude)
        let chosen = AgentAccount(agent: .claude, displayName: "Chosen", home: home("chosen"))
        preferences.preferences.storedAccounts = [top, chosen]
        preferences.preferences.storedProjectSettings = [
            projectURL.path: ProjectSettings(accounts: [.claude: chosen.id])
        ]
        let store = makeStore(preferences)

        XCTAssertEqual(store.newSession(in: projectURL).accountID, chosen.id)
    }

    /// Codex's creation path stamps the same way, and keeps the stamp across the rebuild that
    /// pins the tab to the thread codex named.
    func testACodexTabIsStampedWithTheAccountItRunsAs() async throws {
        let (preferences, work) = configured(.codex)
        let store = makeStore(preferences)
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ThreadStartingTransport())),
            for: .codex, account: work.id
        )

        let result = await store.createSession(agent: .codex, in: projectURL.path)

        guard case .success(let id) = result else { return XCTFail("expected a tab") }
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first { $0.id == id })
        XCTAssertEqual(tab.accountID, work.id)
    }

    // MARK: - What the shell is actually launched with

    func testTheLaunchedShellCarriesItsAccountsVariable() throws {
        let (preferences, work) = configured(.claude)
        let provider = RecordingProvider()
        retained.append(provider)
        let store = makeStore(preferences, provider: provider)

        store.newSession(in: projectURL)

        XCTAssertEqual(
            provider.configs.last?.environmentVariables["CLAUDE_CONFIG_DIR"], work.home.path,
            "the pty is where the account stops being bookkeeping"
        )
    }

    /// A restored tab is launched too, and under the login it was created with rather than
    /// today's default — `restore` goes through the same `insertSession`.
    func testARestoredTabIsRelaunchedUnderTheAccountItWasCreatedWith() {
        let (preferences, work) = configured(.claude)
        let other = AgentAccount(agent: .claude, displayName: "Other", home: home("other"))
        preferences.preferences.storedAccounts = [other, work]   // `other` is now the default
        let provider = RecordingProvider()
        retained.append(provider)
        let persistence = StubPersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "s", workingDirectory: projectURL.path,
                             pinnedConversationID: UUID(), accountID: work.id)],
            sessionCounter: 1
        )
        let store = makeStore(preferences, provider: provider, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))

        XCTAssertEqual(provider.configs.last?.environmentVariables["CLAUDE_CONFIG_DIR"], work.home.path)
    }

    /// The app-server has to live in the same home as the tabs it serves: it is the process
    /// that writes `session_index.jsonl`, and a stack tailing one home while its process
    /// writes another sees no renames at all.
    func testTheCodexAppServerIsSpawnedInTheHomeItsStackTails() throws {
        let (preferences, work) = configured(.codex)
        let store = makeStore(preferences)

        _ = store.adapter(for: .codex, account: work.id)

        let spawned = try XCTUnwrap(store.codexTransportHomeForTesting(account: work.id))
        XCTAssertEqual(spawned, work.home)
        XCTAssertEqual(CodexNameWatcher.indexURL(forHome: spawned), store.codexIndexURL(for: work.id))
    }

    /// And the binding is by variable, not by hope: the spawn environment names `CODEX_HOME`
    /// over whatever Flight Deck itself was launched with.
    func testTheTransportsSpawnEnvironmentOverridesTheInheritedHome() throws {
        let transport = CodexProcessTransport(home: URL(fileURLWithPath: "/tmp/codex-work"))
        let environment = try XCTUnwrap(transport.spawnEnvironment)
        XCTAssertEqual(environment["CODEX_HOME"], "/tmp/codex-work")
        XCTAssertNil(CodexProcessTransport().spawnEnvironment,
                     "no home means inherit, exactly as before")
    }

    // MARK: - Fixtures

    /// Answers `thread/start` and accepts everything else, so a codex creation completes
    /// without a process. Same shape as `CodexLaunchFailureTests.ScriptedTransport`, which is
    /// private to that file.
    private final class ThreadStartingTransport: CodexTransport {
        var onLine: ((String) -> Void)?

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(UUID().uuidString)","path":"/r/t.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private final class SpyReporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }

    /// Keeps every configuration it was handed — the environment is the assertion.
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    /// Restores a posed snapshot and discards every write, so nothing here reaches the
    /// developer's `sessions.json`.
    private final class StubPersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private var reporter = SpyReporter()
    /// `SessionStore.provider` is weak, so a provider held only by the store deallocates
    /// before it is ever asked for a surface — same retention trick as `CodexLaunchFailureTests`.
    private var retained: [RecordingProvider] = []
    private var roots: [URL] = []

    /// Every store gets the spy reporter, not only the tests that assert on it: the default
    /// is an `NSAlert`, and a refusal in any test here would otherwise put a real panel on
    /// the machine running the suite. The two observation overrides keep the watchers off the
    /// developer's real registry for the same reason.
    private func makeStore(
        _ preferences: PreferencesStore,
        provider: SurfaceProvider? = nil,
        persistence: SessionPersisting? = nil
    ) -> SessionStore {
        let store = SessionStore(provider: provider, persistence: persistence, preferences: preferences)
        store.launchFailureReporter = reporter
        store.transcriptsRootOverride = temporaryRoot("projects")
        store.statusRootOverride = temporaryRoot("status")
        return store
    }

    /// One account for `agent`, homed in a directory that really exists — the home check is
    /// part of what is under test, so a fixture that skipped this would fail for the wrong
    /// reason.
    private func configured(_ agent: AgentID) -> (PreferencesStore, AgentAccount) {
        let account = AgentAccount(agent: agent, displayName: "Work", home: home("work"))
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [account]
        return (preferences, account)
    }

    private func home(_ name: String) -> URL {
        let url = temporaryRoot(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryRoot(_ name: String) -> URL {
        let url = suite.appendingPathComponent(name, isDirectory: true)
        roots.append(url)
        return url
    }

    private lazy var suite = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("account-launch-\(UUID().uuidString)", isDirectory: true)

    private lazy var projectURL = home("project")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: suite)
        retained.removeAll()
        roots.removeAll()
    }
}
