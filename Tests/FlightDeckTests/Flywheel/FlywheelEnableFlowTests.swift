import XCTest
@testable import FlightDeck

/// Task 8: the opt-in flow — `SessionStore.enableFlywheel(for:)`, the
/// `flywheelSuggestion(for:)` cache it and the context-menu item read, and the probe-on-add
/// choke point (`insertSession`'s new-repo branch) that populates it. The SwiftUI menu item
/// and confirmation dialog themselves are exercised by the Task 9 smoke test, not here.
@MainActor
final class FlywheelEnableFlowTests: XCTestCase {
    private final class FakeRunner: FlywheelProcessRunner, @unchecked Sendable {
        var exitCode: Int32
        private(set) var argv: [[String]] = []
        init(exitCode: Int32 = 0) { self.exitCode = exitCode }
        func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
            argv.append([exe] + args)
            return ("", exitCode)
        }
    }

    /// `setupFlywheel`'s bootstrap (`FlywheelSetup.initialize`) shells out to real `br`/`am`
    /// commands that create `.beads/`, `AGENTS.md` and `.agent-mail.yaml` — this fake
    /// simulates just enough of that so `testSetupFlywheelOnPlainRepo...` below can assert
    /// on the filesystem the way `FlywheelInitializeTests` does, rather than only on argv.
    private final class BootstrappingFakeRunner: FlywheelProcessRunner, @unchecked Sendable {
        var exitCode: Int32
        var failingArgv: [String]?
        init(exitCode: Int32 = 0) { self.exitCode = exitCode }

        func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
            let full = [exe] + args
            if let failingArgv, full.starts(with: failingArgv) { return ("boom", 1) }
            guard let cwd else { return ("", exitCode) }
            if args.first == "init" {
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: cwd).appendingPathComponent(".beads"), withIntermediateDirectories: true
                )
            }
            if args.first == "projects" {
                try? Data().write(to: URL(fileURLWithPath: cwd).appendingPathComponent(".agent-mail.yaml"))
            }
            return ("", exitCode)
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

    /// A directory that really exists (`enableFlywheel`/the probe both stat it), with `.beads/`
    /// so `FlywheelProjectProbe.status(of:)` reads it as a flywheel project — matching
    /// `FlywheelSetupTests.repo(_:)`'s convention.
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

    private func makeStore(preferences: PreferencesStore, setup: FlywheelSetup) -> SessionStore {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(
            provider: provider, persistence: nil, preferences: preferences, flywheelSetup: setup
        )
        store.launchFailureReporter = reporter
        let scratch = plainRepo()
        store.transcriptsRootOverride = scratch
        store.codexIndexURLOverride = scratch.appendingPathComponent("session_index.jsonl")
        return store
    }

    func testEnableFlywheelSetsFlagOnSuccess() async throws {
        let repo = flywheelRepo()
        let preferences = PreferencesStore(persistence: nil)
        let setup = FlywheelSetup(runner: FakeRunner(exitCode: 0), amPath: "am")
        let store = makeStore(preferences: preferences, setup: setup)

        await store.enableFlywheel(for: repo)

        XCTAssertEqual(store.preferences?.projectSettings(repo.path).flywheelEnabled, true)
        XCTAssertTrue(reporter.reported.isEmpty)
    }

    func testEnableFlywheelFailureLeavesFlagUnset() async throws {
        let repo = flywheelRepo()
        let preferences = PreferencesStore(persistence: nil)
        let setup = FlywheelSetup(runner: FakeRunner(exitCode: 1), amPath: "am")
        let store = makeStore(preferences: preferences, setup: setup)

        await store.enableFlywheel(for: repo)

        XCTAssertNotEqual(store.preferences?.projectSettings(repo.path).flywheelEnabled, true)
        XCTAssertEqual(reporter.reported.count, 1)
    }

    func testProbeOnAddPopulatesSuggestionForFlywheelProject() {
        let flywheel = flywheelRepo()
        let plain = plainRepo()
        let preferences = PreferencesStore(persistence: nil)
        let store = makeStore(preferences: preferences, setup: FlywheelSetup(runner: FakeRunner(), amPath: "am"))

        _ = store.addProject(at: flywheel)
        _ = store.addProject(at: plain)

        XCTAssertNotNil(store.flywheelSuggestion(for: flywheel))
        XCTAssertNil(store.flywheelSuggestion(for: plain))
    }

    /// `setupFlywheel` — the "Setup Flywheel…" menu item's target for a plain repo (no
    /// cached suggestion, since `insertSession` never found `.beads`/`.agent-mail.yaml` in
    /// it). Bootstraps those markers via `FlywheelSetup.initialize`, then runs the same
    /// guard/hook install `enableFlywheel` does, then flips the flag — all three should be
    /// visible afterward.
    func testSetupFlywheelOnPlainRepoBootstrapsAndEnables() async throws {
        let repo = plainRepo()
        let preferences = PreferencesStore(persistence: nil)
        let setup = FlywheelSetup(runner: BootstrappingFakeRunner(exitCode: 0), amPath: "am", brPath: "br")
        let store = makeStore(preferences: preferences, setup: setup)

        await store.setupFlywheel(for: repo)

        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".git/hooks/hooks.d/pre-commit/60-beads-sync.sh").path
        ))
        XCTAssertEqual(store.preferences?.projectSettings(repo.path).flywheelEnabled, true)
        XCTAssertTrue(reporter.reported.isEmpty)
    }

    func testSetupFlywheelFailureLeavesFlagUnsetAndUninitialized() async throws {
        let repo = plainRepo()
        let preferences = PreferencesStore(persistence: nil)
        let fake = BootstrappingFakeRunner(exitCode: 0)
        fake.failingArgv = ["br", "init"]
        let setup = FlywheelSetup(runner: fake, amPath: "am", brPath: "br")
        let store = makeStore(preferences: preferences, setup: setup)

        await store.setupFlywheel(for: repo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads").path))
        XCTAssertNotEqual(store.preferences?.projectSettings(repo.path).flywheelEnabled, true)
        XCTAssertEqual(reporter.reported.count, 1)
    }
}
