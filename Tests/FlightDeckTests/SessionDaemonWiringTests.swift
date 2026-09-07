import XCTest
@testable import FlightDeck

/// Task 5: the two surface-creation sites (`insertSession`, reached here through `newSession`,
/// and `respawnSurface`) must launch through `fd-abduco` — attach to a live daemon, else
/// cold-create — rather than a bare shell. `LaunchPlan`/`SessionDaemon`/`DaemonControlling` are
/// already covered on their own; this only checks the wiring: that `SessionStore` actually calls
/// them, with the right session id, and lands the result in the surface config it hands to
/// `provider`.
@MainActor
final class SessionDaemonWiringTests: XCTestCase {
    /// Same idiom as `RespawnSurfaceTests.CapturingProvider`: records the config it was handed
    /// rather than just reporting a health signal.
    private final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    /// A `DaemonControlling` whose answer is forced rather than derived from any real socket —
    /// the point is to drive `SessionStore` down each branch of `LaunchPlan.decide` on demand.
    private final class FakeDaemonControl: DaemonControlling {
        var forcedIsLive = false
        private(set) var queriedIDs: [UUID] = []

        func isLive(_ id: UUID) -> Bool {
            queriedIDs.append(id)
            return forcedIsLive
        }
        func daemonPID(_ id: UUID) -> pid_t? { nil }
        func terminate(_ id: UUID) {}
    }

    private var tempDir: URL!
    private var fakeBinary: URL!

    override func setUpWithError() throws {
        // Space-free, like `SessionDaemonPathsTests`: the whole point of the symlink under test
        // is to hide the real (space-containing) app-bundle path from ghostty's tokenizer.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-session-daemon-wiring-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        fakeBinary = tempDir.appendingPathComponent("fake-fd-abduco")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(
        provider: SurfaceProvider, daemonControl: DaemonControlling
    ) -> (store: SessionStore, daemon: SessionDaemon) {
        let daemon = SessionDaemon(
            directory: tempDir.appendingPathComponent("run"), bundledBinary: fakeBinary
        )
        let store = SessionStore(
            provider: provider, persistence: nil, preferences: nil,
            daemon: daemon, daemonControl: daemonControl
        )
        return (store, daemon)
    }

    // MARK: - insertSession (via newSession)

    func testNewSessionAttachesWhenDaemonIsLive() throws {
        let provider = CapturingProvider()
        let control = FakeDaemonControl()
        control.forcedIsLive = true
        let (store, daemon) = makeStore(provider: provider, daemonControl: control)

        let session = store.newSession(in: tempDir)

        let config = try XCTUnwrap(provider.configs.last)
        let expectedAttach = try daemon.attachCommand(for: session.id)
        XCTAssertEqual(config.command, expectedAttach)
        XCTAssertEqual(config.initialInput, "")
        XCTAssertEqual(control.queriedIDs.last, session.id)
    }

    func testNewSessionColdCreatesWhenDaemonIsNotLive() throws {
        let provider = CapturingProvider()
        let control = FakeDaemonControl()
        control.forcedIsLive = false
        let (store, daemon) = makeStore(provider: provider, daemonControl: control)

        let session = store.newSession(in: tempDir)

        let config = try XCTUnwrap(provider.configs.last)
        let shell = store.preferences?.resolvedShell() ?? ShellResolver.resolve()
        let expectedColdCreate = try daemon.coldCreateCommand(for: session.id, shell: shell)
        XCTAssertEqual(config.command, expectedColdCreate)
        XCTAssertFalse((config.initialInput ?? "").isEmpty)
        XCTAssertEqual(control.queriedIDs.last, session.id)
    }

    // MARK: - respawnSurface

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    /// Builds a store carrying one inert tab (a `StubProvider`-style nil-returning provider, so
    /// nothing is ever recorded in the process registry) restored from a one-session snapshot —
    /// same setup `RespawnSurfaceTests.inertStore` uses, but wired to the fakes this file needs.
    private func inertStore(
        daemonControl: DaemonControlling
    ) -> (store: SessionStore, daemon: SessionDaemon, id: UUID, provider: CapturingProvider) {
        let id = UUID()
        let entry = SessionSnapshot.Entry(id: id, title: "inert", workingDirectory: tempDir.path)
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [entry], selectedSessionID: nil, sessionCounter: 1
        )
        let daemon = SessionDaemon(
            directory: tempDir.appendingPathComponent("run"), bundledBinary: fakeBinary
        )
        let provider = CapturingProvider()
        let store = SessionStore(
            provider: provider, persistence: persistence, preferences: nil,
            daemon: daemon, daemonControl: daemonControl
        )
        _ = store.restore()
        return (store, daemon, id, provider)
    }

    func testRespawnSurfaceAttachesWhenDaemonIsLive() throws {
        let control = FakeDaemonControl()
        control.forcedIsLive = true
        let (store, daemon, id, provider) = inertStore(daemonControl: control)

        _ = store.respawnSurface(for: id)

        let config = try XCTUnwrap(provider.configs.last)
        let expectedAttach = try daemon.attachCommand(for: id)
        XCTAssertEqual(config.command, expectedAttach)
        XCTAssertEqual(config.initialInput, "")
    }

    func testRespawnSurfaceColdCreatesWhenDaemonIsNotLive() throws {
        let control = FakeDaemonControl()
        control.forcedIsLive = false
        let (store, daemon, id, provider) = inertStore(daemonControl: control)

        _ = store.respawnSurface(for: id)

        let config = try XCTUnwrap(provider.configs.last)
        let shell = store.preferences?.resolvedShell() ?? ShellResolver.resolve()
        let expectedColdCreate = try daemon.coldCreateCommand(for: id, shell: shell)
        XCTAssertEqual(config.command, expectedColdCreate)
        XCTAssertFalse((config.initialInput ?? "").isEmpty)
    }

    // MARK: - Graceful degradation

    /// The production default `SessionDaemon()` resolves `Bundle.main.url(forResource:
    /// withExtension:)`, which is `nil` in the unit-test host — so `resolvedBinaryPath` throws
    /// `binaryNotBundled` and every existing session-creating test must fall back to the old
    /// plain-shell behavior rather than propagate the error.
    func testFallsBackToPlainShellWhenDaemonBinaryIsNotBundled() throws {
        let provider = CapturingProvider()
        // Deliberately the real default `SessionDaemon()`, not one of this file's fakes.
        let store = SessionStore(
            provider: provider, persistence: nil, preferences: nil,
            daemonControl: FakeDaemonControl()
        )

        let session = store.newSession(in: tempDir)

        let config = try XCTUnwrap(provider.configs.last)
        let expectedShell = store.preferences?.resolvedShell() ?? ShellResolver.resolve()
        XCTAssertEqual(config.command, expectedShell)
        XCTAssertFalse((config.initialInput ?? "").isEmpty)
        _ = session
    }
}
