// Tests/FlightDeckTests/SessionLaunchTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionLaunchTests: XCTestCase {
    final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    func testLaunchesClaudeBoundToSessionUUID() {
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))

        let input = try? XCTUnwrap(provider.configs.first?.initialInput)
        XCTAssertEqual(
            input,
            "claude --session-id \(session.id.uuidString.lowercased()) --name '\(session.title)'\n"
        )
    }

    func testStillLaunchesTheShellAsTheCommand() {
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider)
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(provider.configs.first?.command, ShellResolver.resolve())
    }

    // MARK: - Preferences wiring

    func testNewSessionLaunchesWithResolvedFlags() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.agents = [
            AgentSettings(id: .claude, options: .claude(FlagSet(values: ["--model": .value("opus")])))
        ]
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        XCTAssertTrue(provider.configs.last?.initialInput?.contains("--model opus") == true)
    }

    func testProjectOverrideBeatsGlobalAtLaunch() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.agents = [
            AgentSettings(id: .claude, options: .claude(FlagSet(values: ["--model": .value("opus")])))
        ]
        preferences.setProjectSettings(
            "/tmp",
            ProjectSettings(options: [.claude: .claude(FlagSet(values: ["--model": .value("sonnet")]))])
        )
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        let input = provider.configs.last?.initialInput ?? ""
        XCTAssertTrue(input.contains("--model sonnet"))
        XCTAssertFalse(input.contains("--model opus"))
    }

    func testShellOverrideReachesTheSurfaceConfig() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.shell.shellOverride = "/bin/fish"
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        XCTAssertEqual(provider.configs.last?.command, "/bin/fish")
    }

    func testCustomEnvironmentReachesTheSurfaceConfig() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.shell.environment = ["FOO": "bar"]
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        XCTAssertEqual(provider.configs.last?.environmentVariables["FOO"], "bar")
    }

    /// The line that makes the persisted font size actually do anything: without it, a
    /// bumped `Preferences.terminalFontSize` would only ever reach surfaces already open at
    /// bump time (via `SessionStore.applyTerminalFontSize`), and every session opened after
    /// would silently come back at libghostty's config default.
    func testPersistedFontSizeReachesTheSurfaceConfig() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.terminalFontSize = 18
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        XCTAssertEqual(provider.configs.last?.fontSize, 18)
    }

    /// The other half: an unset size must reach the surface as `nil`, not as some
    /// materialized default — `SurfaceConfiguration.withCValue` is what maps `nil` to `0`
    /// ("inherit libghostty's configured default"), and only does that for an actual `nil`.
    func testUnsetFontSizeReachesTheSurfaceConfigAsNil() {
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider, persistence: nil)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        XCTAssertNil(provider.configs.last?.fontSize)
    }

    func testStoreWithoutPreferencesStillLaunches() {
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider, persistence: nil)
        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertTrue(provider.configs.last?.initialInput?.hasPrefix("claude --session-id") == true)
    }

    func testRestoreResolvesFlagsPerEntryWorkingDirectory() {
        let sessionPersistence = SessionPersistenceTests.FakePersistence()
        let firstID = UUID()
        let secondID = UUID()
        sessionPersistence.stored = SessionSnapshot(
            sessions: [
                .init(id: firstID, title: "one", workingDirectory: "/tmp/one"),
                .init(id: secondID, title: "two", workingDirectory: "/tmp/two"),
            ],
            selectedSessionID: firstID,
            sessionCounter: 2
        )
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.agents = [
            AgentSettings(id: .claude, options: .claude(FlagSet(values: ["--model": .value("opus")])))
        ]
        preferences.setProjectSettings(
            "/tmp/two",
            ProjectSettings(options: [.claude: .claude(FlagSet(values: ["--model": .value("sonnet")]))])
        )
        let provider = CapturingProvider()
        let store = SessionStore(
            provider: provider, persistence: sessionPersistence, preferences: preferences
        )

        store.restore(directoryExists: { _ in true })

        XCTAssertEqual(provider.configs.count, 2)
        XCTAssertTrue(provider.configs[0].initialInput?.contains("--model opus") == true)
        XCTAssertTrue(provider.configs[1].initialInput?.contains("--model sonnet") == true)
    }
}
