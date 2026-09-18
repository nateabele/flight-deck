import XCTest
@testable import FlightDeck

/// Task 7b: `SessionStore.newClaudeTab(in:...)`, the helper every user-facing claude
/// tab-creation entry point (⌘N's context-menu counterpart, Add Project, the project header's
/// "New Session", a folder drop, and the phone's plain `+` tap) is rerouted through. Mirrors
/// `FlywheelSpawnTests`' harness (a real `SessionStore` with a fake reporter/provider and a
/// scripted `am` runner) since this is the same seam, one level up: `createSession` already
/// boots and stamps an identity (Task 7a), this only pins that the *synchronous* claude
/// tab-creation entry points reach it for a flywheel-enabled project, and leave it alone for
/// every project that has not opted in.
@MainActor
final class NewClaudeTabFlywheelTests: XCTestCase {
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

    /// Same tempdir convention `FlywheelSpawnTests.project()` uses — a directory that really
    /// exists, since `bootFlywheelIdentityIfNeeded` standardizes it before recording it.
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

    func testFlywheelProjectRoutesThroughCreateSessionAndStampsTheBootedIdentity() async throws {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)
        preferences.setProjectSettings(url.path, ProjectSettings(flywheelEnabled: true))
        let fake = FakeRunner(stdout: Self.blueFalconJSON)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))

        _ = store.newClaudeTab(in: url)

        // `newClaudeTab` cannot hand back the booted tab synchronously — the boot is async and
        // this call stays synchronous, matching every existing desk caller. Poll for the `Task`
        // it fired, the same idiom `AgentRoutingTests`/`SessionStorePlanGateIntegrationTests`
        // use for a store mutation that lands a turn later.
        for _ in 0..<100 where store.repos.flatMap(\.sessions).isEmpty { await Task.yield() }

        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first)
        XCTAssertEqual(tab.flywheelIdentity?.agentName, "BlueFalcon")
        XCTAssertEqual(fake.argv.count, 1, "exactly one `am` boot, before the pty forks")
    }

    func testNonFlywheelProjectStaysOnTheSyncPathWithNoIdentityAndNoCoordinatorCalls() {
        let url = project()
        let preferences = PreferencesStore(persistence: nil)   // no flywheelEnabled anywhere
        let fake = FakeRunner(stdout: Self.blueFalconJSON)
        let store = makeStore(preferences: preferences, coordinator: FlywheelCoordinator(runner: fake))

        let created = store.newClaudeTab(in: url)

        // Synchronous and already filed — unlike the flywheel branch above, a non-flywheel
        // project must see today's behaviour with no `Task`, no delay and no `am` call.
        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.id), [created.id])
        XCTAssertNil(created.flywheelIdentity)
        XCTAssertTrue(fake.argv.isEmpty, "a non-flywheel project must never shell out to `am`")
    }
}
