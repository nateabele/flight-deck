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

    /// The New Session dropdown's whole point (Task 14): naming an account explicitly must
    /// reach the tab it creates even when it disagrees with what the project would have
    /// resolved on its own — that disagreement is exactly what the dropdown exists to let
    /// past. Goes through `createFromMenu`, the same entry point the dropdown's `Button`
    /// calls, not the lower-level `createSession` the earlier stamping tests use.
    func testAnExplicitlyChosenAccountReachesTheStamp() async throws {
        let (preferences, top) = configured(.claude)
        let chosen = AgentAccount(agent: .claude, displayName: "Chosen", home: home("chosen"))
        preferences.preferences.storedAccounts = [top, chosen]
        let store = makeStore(preferences)
        store.newSession(in: projectURL)   // an active project to add the chosen tab beside

        let created = await store.createFromMenu(
            agent: .claude, chooseFolder: { XCTFail("must not prompt"); return nil },
            account: chosen.id
        )

        let tab = try XCTUnwrap(created, "the dropdown's choice must still produce a tab")
        XCTAssertEqual(tab.accountID, chosen.id,
                       "the account clicked in the dropdown, not the project's own default")
        XCTAssertNotEqual(chosen.id, top.id, "the fixture must actually disagree with the default")
    }

    // MARK: - The sidebar's account-mismatch marker

    /// `accountMismatchedSessionIDs` is what actually decides which sessions get
    /// `SessionSidebar`'s marker — `SidebarRow.accountMismatched` (a pure `UUID?` comparison)
    /// and `PreferencesStore.resolvedAccounts` are each covered on their own elsewhere, but
    /// neither test exercises the wiring here: which session field feeds which side of the
    /// comparison, and against which project. A swapped argument or a wrong field would pass
    /// both of those tests and this whole suite while silently marking every tab, or none.
    ///
    /// The common case first: a tab running as its own project's current default carries no
    /// marker.
    func testASessionMatchingItsProjectAccountIsNotMismatched() {
        let (preferences, _) = configured(.claude)
        let store = makeStore(preferences)
        let session = store.newSession(in: projectURL)

        XCTAssertFalse(store.accountMismatchedSessionIDs.contains(session.id))
    }

    /// A tab explicitly stamped with one login, left in a project whose own (unassigned)
    /// default resolves to another — exactly what the marker exists to surface.
    func testASessionOnADifferentAccountThanItsProjectIsMismatched() {
        let (preferences, top) = configured(.claude)
        let other = AgentAccount(agent: .claude, displayName: "Other", home: home("other"))
        preferences.preferences.storedAccounts = [top, other]
        let store = makeStore(preferences)

        let session = store.newSession(in: projectURL, account: other.id)

        XCTAssertNotEqual(other.id, top.id, "the fixture must actually disagree with the default")
        XCTAssertTrue(store.accountMismatchedSessionIDs.contains(session.id))
    }

    /// Degrades to nothing rather than guessing, the same as `conflictedSessionIDs` does —
    /// there is nothing to resolve a mismatch against without a `PreferencesStore`.
    func testWithNoPreferencesStoreNothingIsEverMismatched() {
        let store = SessionStore(provider: nil, persistence: nil)
        store.newSession(in: projectURL)

        XCTAssertTrue(store.accountMismatchedSessionIDs.isEmpty)
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

    /// The default account's variable is written out, not left implicit.
    ///
    /// `CLAUDE_CONFIG_DIR=~/.claude` is exactly equivalent to setting nothing, which makes
    /// "skip it for the built-in account" a tempting simplification — and a silent one, since
    /// every other test here uses a *configured* account and would still pass. It is not
    /// equivalent: unset means the agent inherits whatever Flight Deck itself was launched
    /// with, so a Flight Deck started from a shell that exports `CLAUDE_CONFIG_DIR` would put
    /// every default-account tab on someone else's login. Always stating it removes the
    /// inheritance entirely.
    func testTheDefaultAccountsVariableIsStatedExplicitlyRatherThanInherited() {
        let builtIn = AgentAccount(
            agent: .claude, displayName: "Default", home: AgentID.claude.builtInHome
        )
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [builtIn]
        let provider = RecordingProvider()
        retained.append(provider)
        let store = makeStore(preferences, provider: provider)

        store.newSession(in: projectURL)

        XCTAssertEqual(
            provider.configs.last?.environmentVariables["CLAUDE_CONFIG_DIR"],
            AgentID.claude.builtInHome.path,
            "the built-in home must be spelled out, never left to the launch environment"
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

    /// Deleting an account does not rewrite the tabs that ran as it — `removeAccount` clears
    /// project *assignments*, while `Session.accountID` is history and must stay what it was.
    /// So a restored tab can name a login that is gone, and relaunching it in the built-in home
    /// would resume a conversation living in the deleted account's directory, find nothing, and
    /// quietly start a fresh one. That is the same silent substitution creation already
    /// refuses, arriving through the one door creation does not guard.
    ///
    /// Both tabs come back in one restore, deliberately: the healthy one is the control that
    /// proves the refusal is aimed rather than a blanket "restore stopped resuming things".
    func testARestoredTabWhoseLoginWasDeletedIsNotRelaunchedAsAnotherLogin() throws {
        let (preferences, work) = configured(.claude)
        let healthy = UUID(), orphan = UUID()
        let provider = RecordingProvider()
        retained.append(provider)
        let persistence = StubPersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: healthy, title: "healthy", workingDirectory: projectURL.path,
                      pinnedConversationID: UUID(), accountID: work.id),
                // The login this one ran as was deleted between runs.
                .init(id: orphan, title: "orphan", workingDirectory: projectURL.path,
                      pinnedConversationID: UUID(), accountID: UUID()),
            ],
            sessionCounter: 2
        )
        let store = makeStore(preferences, provider: provider, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))

        // The tab is still there. A tab that vanished at relaunch would be its own bug: the
        // user has to be able to see which tabs this hit, read their titles, and close them.
        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.id), [healthy, orphan])

        XCTAssertEqual(provider.configs.count, 2)
        let restored = provider.configs[0], refused = provider.configs[1]
        XCTAssertEqual(restored.environmentVariables["CLAUDE_CONFIG_DIR"], work.home.path)
        XCTAssertEqual(restored.initialInput?.isEmpty, false, "the healthy tab still resumes")

        XCTAssertNil(refused.environmentVariables["CLAUDE_CONFIG_DIR"],
                     "no variable at all beats one naming somebody else's home")
        XCTAssertEqual(refused.initialInput, "",
                       "nothing may be typed into a tab that cannot launch as itself")
        XCTAssertEqual(store.watchedSessionIDs, [healthy],
                       "observation has to agree with the launch, and this one did not launch")
        XCTAssertEqual(reporter.reported, [.accountMissing("Claude")],
                       "a refusal nobody is told about is the silent wrong-login bug again")
    }

    /// A deleted login usually takes several tabs with it, and five identical sheets is not
    /// five times the information.
    func testEveryTabOnADeletedLoginRaisesOneAlert() {
        let (preferences, _) = configured(.claude)
        let gone = UUID()
        let persistence = StubPersistence()
        persistence.stored = SessionSnapshot(
            sessions: (0..<3).map { i in
                .init(id: UUID(), title: "t\(i)", workingDirectory: projectURL.path,
                      pinnedConversationID: UUID(), accountID: gone)
            },
            sessionCounter: 3
        )
        let store = makeStore(preferences, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))

        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 3)
        XCTAssertEqual(reporter.reported, [.accountMissing("Claude")])
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
