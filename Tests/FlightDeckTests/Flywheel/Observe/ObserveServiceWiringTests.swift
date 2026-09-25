import XCTest
@testable import FlightDeck

/// Task 12 fix round: real `SessionStore`-level Observe integration tests. The predecessor
/// this replaces drove `FlywheelObserveService` directly — which just re-tested Task 7's
/// `FlywheelObserveServiceTests` and could never go RED against the actual `SessionStore`
/// wiring (the mount points `RootView`/`ObserveDrawer` call: `enableFlywheel(for:)`,
/// `focusedObserveAgent()`, `selectObserveSession(forBeadID:)`, `jumpToObserveRootCause()`).
/// Mirrors `FlywheelEnableFlowTests`' harness (a real `SessionStore`, fake provider/reporter)
/// plus the shared `MultiRunner` fake (`ObserveTestSupport.swift`), injected through the
/// `flywheelObserveReads` seam this fix round added to `SessionStore`'s designated init —
/// so every assertion here asserts on argv without spawning real `am`/`br`.
@MainActor
final class ObserveServiceWiringTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private final class SpyReporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }

    /// `enableFlywheel(for:)`'s own setup step (`FlywheelSetup.enable`, guard/hook install)
    /// runs BEFORE `startObserving` — the real runner's default `SessionStore()` would shell
    /// to a real `am` and either hang or fail outside a flywheel-tooled environment, which
    /// would make `startObserving` (and therefore every read this suite fakes) never run.
    /// Mirrors `FlywheelEnableFlowTests.FakeRunner` so setup always succeeds silently,
    /// isolating these tests to exercising the Observe wiring specifically.
    private final class FakeRunner: FlywheelProcessRunner, @unchecked Sendable {
        var exitCode: Int32
        init(exitCode: Int32 = 0) { self.exitCode = exitCode }
        func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
            ("", exitCode)
        }
    }

    private var reporter = SpyReporter()
    private var retainedProviders: [StubProvider] = []
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    /// Same convention `FlywheelEnableFlowTests.flywheelRepo()` uses — a directory that
    /// really exists, with `.beads/`, so `enableFlywheel`/the probe treat it as a flywheel
    /// project.
    private func flywheelRepo() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent(".beads"), withIntermediateDirectories: true
        )
        roots.append(root)
        return root
    }

    private func plainRepo() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// `reads` is always a `MultiRunner`-backed `FlywheelReadCommands` here — the seam this
    /// fix round added (`SessionStore`'s `flywheelObserveReads` init parameter) so a test can
    /// assert on argv without a real `am`/`br` on PATH. `flywheelSetup` defaults to the local
    /// `FakeRunner` (always exit 0) so `enableFlywheel(for:)`'s setup step never shells to a
    /// real `am` — see `FakeRunner`'s doc comment.
    private func makeStore(
        reads: FlywheelReadCommands,
        flywheelSetup: FlywheelSetup = FlywheelSetup(runner: FakeRunner(exitCode: 0), amPath: "am")
    ) -> SessionStore {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(
            provider: provider, persistence: nil, preferences: PreferencesStore(persistence: nil),
            flywheelSetup: flywheelSetup, flywheelObserveReads: reads
        )
        store.launchFailureReporter = reporter
        let scratch = plainRepo()
        store.transcriptsRootOverride = scratch
        store.codexIndexURLOverride = scratch.appendingPathComponent("session_index.jsonl")
        return store
    }

    // MARK: 1. Enable populates the focused projection

    /// `enableFlywheel(for:)` → `startObserving` → `observeService.enable` fires a
    /// fire-and-forget priming `repollNow()` (`FlywheelObserveService.swift:63-67`), so the
    /// projection lands a beat after `enableFlywheel` itself returns — poll for it the same
    /// way `NewClaudeTabFlywheelTests` polls for its async boot.
    func testEnablePopulatesFocusedProjection() async throws {
        let repo = flywheelRepo()
        let fake = MultiRunner()
        fake.responses["am agents list"] = (#"[{"name":"BlueFalcon"}]"#, 0)
        let store = makeStore(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"))
        let project = FlywheelObserveService.key(repo.path)

        // Constructed the way `FlywheelIdentityPersistenceTests.swift:22` builds an
        // identity-bearing session, filed via the real, synchronous `newSession(in:...)`
        // seam (not the async flywheel-boot path `NewClaudeTabFlywheelTests` exercises —
        // that derives the identity from a boot; this test hands one in directly).
        let session = store.newSession(
            in: repo, flywheelIdentity: FlywheelIdentity(agentName: "BlueFalcon", project: project)
        )
        store.selectedSessionID = session.id

        await store.enableFlywheel(for: repo)
        for _ in 0..<100 where store.focusedObserveAgent() == nil { await Task.yield() }

        let agent = try XCTUnwrap(store.focusedObserveAgent())
        XCTAssertEqual(agent.name, "BlueFalcon")
        XCTAssertTrue(fake.argv.contains { $0.contains(repo.path) }, "the read must be scoped to the enabled project")
    }

    // MARK: 2. selectObserveSession(forBeadID:) resolves to the right tab

    /// Two tabs in the SAME enabled project, under different agent identities — the DAG
    /// overlay's real shape: the focused tab is BlueFalcon's, and clicking a node owned by
    /// RedOtter must move the selection to RedOtter's tab, not leave it on BlueFalcon's or
    /// go nowhere. Proves `selectObserveSession(forBeadID:)`'s bead → assignee → session
    /// resolution end to end through `SessionStore`.
    func testSelectObserveSessionMovesSelectionToTheBeadsAssigneeTab() async throws {
        let repo = flywheelRepo()
        let fake = MultiRunner()
        fake.responses["am agents list"] = (#"[{"name":"BlueFalcon"},{"name":"RedOtter"}]"#, 0)
        fake.responses["br list --status"] = (
            #"{"issues":[{"id":"bd-1","title":"t","status":"in_progress","assignee":"RedOtter"}]}"#, 0
        )
        let store = makeStore(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"))
        let project = FlywheelObserveService.key(repo.path)

        let focused = store.newSession(
            in: repo, flywheelIdentity: FlywheelIdentity(agentName: "BlueFalcon", project: project)
        )
        let target = store.newSession(
            in: repo, selecting: false,
            flywheelIdentity: FlywheelIdentity(agentName: "RedOtter", project: project)
        )
        store.selectedSessionID = focused.id

        await store.enableFlywheel(for: repo)
        for _ in 0..<100 where store.observeService.projection(forProject: project)?.agents.first(where: { $0.bead != nil }) == nil {
            await Task.yield()
        }

        store.selectObserveSession(forBeadID: "bd-1")

        XCTAssertEqual(store.selectedSessionID, target.id)
    }

    /// `jumpToObserveRootCause()`'s real algorithm (Fix 2) requires `DependencyGraphLayout`
    /// to find a `.blocked` node with a `.stalled` node reachable via `depEdges` — but
    /// `FlywheelReadCommands.depEdges(project:)` is a permanent Task 2 nil-stub (never
    /// touches the runner at all) and `FlywheelWatcher.repollNow()` hardcodes
    /// `depEdges: nil` into every snapshot it builds regardless of what a fake runner would
    /// answer for a `br dep`/edges call. That means **no `SessionStore`-level test can ever
    /// seed non-empty edges through the live `enable` → `observeService` →
    /// `FlywheelWatcher` → `FlywheelReadCommands` pipeline with the fakes this suite has** —
    /// there is no test seam that injects a `FlywheelProjection`/edges directly (`projections`
    /// is `@Published private(set)`, and `FlywheelObserveService` exposes no seed hook). A
    /// true root-cause-jump assertion is therefore NOT reachable at the `SessionStore`
    /// boundary today; see task-12-fix-1-report.md. What IS honestly testable through this
    /// pipeline is the consequence of that gap: even a `.blocked` bead never produces a jump,
    /// because there is never an edge to make it reachable from a `.stalled` node.
    func testJumpToRootCauseIsANoOpGivenTheLiveReadPipelinesPermanentlyEmptyEdges() async throws {
        let repo = flywheelRepo()
        let fake = MultiRunner()
        fake.responses["am agents list"] = (#"[{"name":"BlueFalcon"}]"#, 0)
        fake.responses["br list --status"] = (
            #"{"issues":[{"id":"bd-1","title":"t","status":"blocked","assignee":"BlueFalcon"}]}"#, 0
        )
        let store = makeStore(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"))
        let project = FlywheelObserveService.key(repo.path)

        let session = store.newSession(
            in: repo, flywheelIdentity: FlywheelIdentity(agentName: "BlueFalcon", project: project)
        )
        store.selectedSessionID = session.id

        await store.enableFlywheel(for: repo)
        for _ in 0..<100 where store.focusedObserveAgent()?.bead == nil { await Task.yield() }

        let before = store.selectedSessionID
        store.jumpToObserveRootCause()

        XCTAssertEqual(store.selectedSessionID, before, "no edges ⇒ no reachable root cause ⇒ selection unchanged")
    }

    // MARK: 3. Zero-cost guarantee

    /// A project that never called `enableFlywheel` must never touch `observeService` at
    /// all — driven through `SessionStore` (an ordinary tab, never enabled), not the bare
    /// service, so this actually exercises the wiring rather than re-testing Task 7.
    func testDisabledProjectIssuesNoObserveReadsThroughSessionStore() async throws {
        let repo = plainRepo()
        let fake = MultiRunner()
        let store = makeStore(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"))
        _ = store.newSession(in: repo)

        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(fake.argv.isEmpty, "a project that was never enabled must issue zero am/br reads")
    }
}
