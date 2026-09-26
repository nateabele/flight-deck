import XCTest
@testable import FlightDeck

/// Task 7a: booting an Agent-Mail identity BEFORE the pty forks, and stamping it on the
/// `Session` `createSession` returns — the wiring `FlywheelCoordinator` (Task 2),
/// `Session.flywheelIdentity` (Task 5) and `sessionEnvironment(for:flywheel:)` (Task 6) existed
/// for but nothing yet called. Covers both `createSession` branches: claude's synchronous
/// delegation to `newSession`, and codex's `prepare`-then-rebuild.
///
/// Driven at the full `createSession` level throughout — the existing `AccountLaunchTests` /
/// `CodexLaunchFailureTests` harness (a real `SessionStore` with a fake reporter/provider, and
/// for codex a scripted `CodexTransport` behind `overrideAdapter`) makes that practical without
/// touching a real `am` or a real `codex` process.
@MainActor
final class FlywheelSpawnTests: XCTestCase {
    // MARK: - Fixtures

    /// Records every `am` invocation and answers with a canned identity, the same shape
    /// `FlywheelCoordinatorTests`' private fixture uses.
    private final class FakeRunner: FlywheelProcessRunner, @unchecked Sendable {
        var stdout: String
        var exitCode: Int32
        private(set) var argv: [[String]] = []
        init(stdout: String, exitCode: Int32 = 0) { self.stdout = stdout; self.exitCode = exitCode }
        func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
            argv.append([exe] + args)
            return (stdout, exitCode)
        }
    }

    private static let blueFalconJSON = #"{"agent":{"name":"BlueFalcon"},"inbox":[]}"#

    /// Answers `thread/start` and accepts everything else, so a codex creation completes
    /// without a process — the same fixture `AccountLaunchTests.ThreadStartingTransport` uses.
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

    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private var reporter = SpyReporter()
    private var retainedProviders: [StubProvider] = []
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    /// A project directory that really exists, standardized the same way `PreferencesStore.key`
    /// and `bootFlywheelIdentityIfNeeded` both do — `launchAccount`'s account-home check is not
    /// under test here, but a tempdir keeps every fixture below honest about paths regardless.
    private func project() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func makeStore(
        preferences: PreferencesStore, coordinator: FlywheelCoordinator
    ) -> SessionStore {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(
            provider: provider, persistence: nil, preferences: preferences,
            flywheelCoordinator: coordinator
        )
        store.launchFailureReporter = reporter
        store.transcriptsRootOverride = project()
        store.codexIndexURLOverride = roots.last!.appendingPathComponent("session_index.jsonl")
        return store
    }

    // MARK: - `createSession`, claude branch

    func testClaudeSessionInAFlywheelProjectIsStampedWithTheBootedIdentity() async throws {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(url.path, ProjectSettings(flywheelEnabled: true))
        let fake = FakeRunner(stdout: Self.blueFalconJSON)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))

        let result = await store.createSession(agent: .claude, in: url.path)

        guard case .success(let id) = result else { return XCTFail("expected a tab") }
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first { $0.id == id })
        XCTAssertEqual(tab.flywheelIdentity?.agentName, "BlueFalcon")
        XCTAssertEqual(
            preferences.sessionEnvironment(for: nil, flywheel: tab.flywheelIdentity, inherited: [:])["AGENT_NAME"],
            "BlueFalcon"
        )
        XCTAssertEqual(fake.argv.count, 1, "exactly one `am` boot, before the pty forks")
    }

    func testClaudeSessionInANonFlywheelProjectStampsNothingAndNeverCallsAm() async throws {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)   // no flywheelEnabled anywhere
        let fake = FakeRunner(stdout: Self.blueFalconJSON)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))

        let result = await store.createSession(agent: .claude, in: url.path)

        guard case .success(let id) = result else { return XCTFail("expected a tab") }
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first { $0.id == id })
        XCTAssertNil(tab.flywheelIdentity)
        XCTAssertTrue(fake.argv.isEmpty, "a non-flywheel project must never shell out to `am`")
    }

    func testABootFailureRefusesTheTabAndLeavesNoOrphanedSession() async {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(url.path, ProjectSettings(flywheelEnabled: true))
        let fake = FakeRunner(stdout: "", exitCode: 1)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))

        let result = await store.createSession(agent: .claude, in: url.path)

        guard case .failure = result else { return XCTFail("expected a failure") }
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty,
                      "a boot failure must leave no tab behind, exactly like any other launch refusal")
        XCTAssertEqual(reporter.reported.count, 1, "the refusal must reach the user")
    }

    // MARK: - `createSession`, codex branch

    func testCodexSessionInAFlywheelProjectIsStampedWithTheBootedIdentity() async throws {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(url.path, ProjectSettings(flywheelEnabled: true))
        let fake = FakeRunner(stdout: Self.blueFalconJSON)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ThreadStartingTransport()), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )

        let result = await store.createSession(agent: .codex, in: url.path)

        guard case .success(let id) = result else { return XCTFail("expected a tab") }
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first { $0.id == id })
        XCTAssertEqual(tab.flywheelIdentity?.agentName, "BlueFalcon")
        // `[exe, "macros", "start-session", "--project", <path>, "--program", <program>, ...]`
        // — the same argv shape `FlywheelCoordinatorTests` pins.
        XCTAssertEqual(fake.argv.first?[safeFlywheelIndex: 6], "codex-cli",
                       "codex boots under its own `--program`, not claude's")
    }

    /// The codex-branch counterpart of `testABootFailureRefusesTheTabAndLeavesNoOrphanedSession`.
    /// `prepare` succeeds (codex genuinely named a thread) and ONLY THEN does the boot fail —
    /// the ordering `createSession`'s codex branch uses — so this also pins that a thread
    /// negotiated just before a refused creation does not leave `codexCreationsInFlight` or the
    /// app-server dangling. The stack is built explicitly first (`adapter(for:account:)`,
    /// same trick `CodexLaunchFailureTests.testTheDeferredTeardownRunsOnceTheCreationFinishes`
    /// uses) so `hasCodexStackForTesting` going true→false is actually informative rather than
    /// trivially false because nothing was ever built.
    func testACodexBootFailureRefusesTheTabAndTearsDownTheAppServer() async {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(url.path, ProjectSettings(flywheelEnabled: true))
        let fake = FakeRunner(stdout: "", exitCode: 1)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))
        // `createSession` keys its stack/adapter/teardown off `instance(for: draft).account`,
        // which `resolvedAccountID` resolves to preferences' seeded built-in codex account —
        // NOT nil — the moment a real `PreferencesStore` (rather than no preferences at all)
        // is in play. Building the fixture under that same id, rather than nil, is what makes
        // `hasCodexStackForTesting` going true→false actually pin the real teardown instead of
        // leaving an unrelated nil-keyed stack stranded while `createSession` tears down a
        // different one.
        let accountID = preferences.account(for: .codex, project: url.path)?.id
        _ = store.adapter(for: .codex, account: accountID)
        XCTAssertTrue(store.hasCodexStackForTesting, "the fixture must actually build a stack to tear down")
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ThreadStartingTransport()), rolloutExists: { _ in true }),
            for: .codex, account: accountID
        )

        let result = await store.createSession(agent: .codex, in: url.path)

        guard case .failure = result else { return XCTFail("expected a failure") }
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty,
                      "a boot failure after a successful `prepare` must still leave no tab behind")
        XCTAssertFalse(store.hasCodexStackForTesting,
                       "a failed creation must not leave the app-server running with no codex tab — "
                       + "codexCreationsInFlight must have unwound to 0 for `stopCodexIfUnused` to fire")
        XCTAssertEqual(reporter.reported.count, 1, "the refusal must reach the user")
    }

    // MARK: - `bootFlywheelIdentityIfNeeded` directly

    func testBootFlywheelIdentityIfNeededReturnsNilAndCallsAmZeroTimesWhenTheFlagIsOff() async throws {
        let preferences = PreferencesStore(persistence: nil)
        let fake = FakeRunner(stdout: Self.blueFalconJSON)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))

        let identity = try await store.bootFlywheelIdentityIfNeeded(agent: .claude, project: "/p")

        XCTAssertNil(identity)
        XCTAssertTrue(fake.argv.isEmpty)
    }

    func testBootFlywheelIdentityIfNeededReturnsTheBootedIdentityWhenTheFlagIsOn() async throws {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(url.path, ProjectSettings(flywheelEnabled: true))
        let fake = FakeRunner(stdout: Self.blueFalconJSON)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))

        let identity = try await store.bootFlywheelIdentityIfNeeded(agent: .claude, project: url.path)

        XCTAssertEqual(identity?.agentName, "BlueFalcon")
    }

    func testBootFlywheelIdentityIfNeededThrowsOnABootError() async throws {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(url.path, ProjectSettings(flywheelEnabled: true))
        let fake = FakeRunner(stdout: "", exitCode: 1)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))

        await XCTAssertThrowsErrorAsync(
            try await store.bootFlywheelIdentityIfNeeded(agent: .claude, project: url.path)
        )
    }
}

private extension Array where Element == String {
    /// Bounds-safe indexing for the argv-shape assertion above, so a mismatched argv fails the
    /// assertion rather than crashing the test run.
    subscript(safeFlywheelIndex index: Int) -> String? { indices.contains(index) ? self[index] : nil }
}
