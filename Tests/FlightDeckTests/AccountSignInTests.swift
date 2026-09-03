import XCTest
@testable import FlightDeck

/// The Accounts pane's Sign In path. Everything here is store-level: what gets typed at the
/// shell, and what gets queued to be typed at the agent once it is up.
@MainActor
final class AccountSignInTests: XCTestCase {
    /// Keeps every configuration it was handed — `initialInput` is the assertion.
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    /// `SessionStore.provider` is weak, so a provider held only by the store deallocates
    /// before it is ever asked for a surface.
    private var retained: [RecordingProvider] = []
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        retained = []
    }

    /// A command with no trailing newline is typed and never run: `initial_input` reaches the
    /// pty verbatim, and nothing downstream presses Return.
    func testAnUnterminatedCommandGainsItsNewline() {
        XCTAssertEqual(SessionStore.terminated("claude"), "claude\n")
        XCTAssertEqual(SessionStore.terminated("codex login"), "codex login\n")
    }

    /// Not doubled: `ClaudeSession.launchCommand` already ends in one, and a blank line typed
    /// at a shell is a stray empty prompt.
    func testAnAlreadyTerminatedCommandIsLeftAlone() {
        XCTAssertEqual(SessionStore.terminated("claude\n"), "claude\n")
    }

    private func makeAccount(_ agent: AgentID, named name: String = "Work") -> AgentAccount {
        AgentAccount(agent: agent, displayName: name, home: root.appendingPathComponent(name))
    }

    private func makeStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider()
        retained.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.transcriptsRootOverride = root.appendingPathComponent("projects")
        store.statusRootOverride = root.appendingPathComponent("status")
        return (store, provider)
    }

    /// The whole point of Task 1, asserted through the real path rather than on the helper.
    func testTheSignInTabIsHandedANewlineTerminatedCommand() {
        let (store, provider) = makeStore()
        store.openSignInSession(
            for: makeAccount(.claude), in: root.path,
            using: LoginInvocation(command: "claude", inject: "/login")
        )
        XCTAssertEqual(provider.configs.last?.initialInput, "claude\n")
    }

    /// The regression test for the misrouting. `/login` must be queued as a prompt; queuing it
    /// as a rename typed `/rename /login` at the tab, renaming the conversation instead of
    /// authenticating and clobbering any genuine pending rename.
    func testSignInQueuesTheInjectionAsAPromptAndNeverAsARename() {
        let (store, _) = makeStore()
        let session = store.openSignInSession(
            for: makeAccount(.claude), in: root.path,
            using: LoginInvocation(command: "claude", inject: "/login")
        )
        XCTAssertEqual(store.pendingPrompts[session.id]?.text, "/login")
        XCTAssertTrue(store.pendingRenamesForTesting.isEmpty, "a login is not a rename")
    }

    /// Queuing it is only half the fix — this is the half a user can see: the queued `/login`
    /// is actually typed at the agent, and typed as itself. Every other test of the prompt
    /// queue drives `Self.resumePrompt`, so a delivery path that special-cased "Keep going",
    /// or a `DeferredPrompt` that lost its own text on the way through, would leave this
    /// suite and the auto-resume suite both green while sign-in silently did nothing.
    func testTheQueuedLoginIsTypedOnceTheAgentIsUp() {
        let (store, _) = makeStore()
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { work in work() }
        let session = store.openSignInSession(
            for: makeAccount(.claude), in: root.path,
            using: LoginInvocation(command: "claude", inject: "/login")
        )

        // Nothing yet: the tab is a bare shell that has not even started `claude`.
        store.flushPendingResumePromptsForTesting()
        XCTAssertTrue(spy.sent.isEmpty, "typing at a shell prompt is how this bug looked")

        // `claude` registers in the status registry and settles.
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .idle)])
        store.flushPendingResumePromptsForTesting()

        XCTAssertEqual(spy.sent, ["/login"])
        XCTAssertEqual(spy.events.last, .ret, "an unsent Return is the defect this replaced")
        XCTAssertNil(store.pendingPrompts[session.id], "one-shot")
    }

    /// Codex signs in with a one-shot subcommand and has nothing to type afterwards, so it
    /// must not leave an entry sitting in the queue until its deadline.
    func testAnAgentWithNothingToInjectQueuesNothing() {
        let (store, provider) = makeStore()
        let session = store.openSignInSession(
            for: makeAccount(.codex), in: root.path,
            using: LoginInvocation(command: "codex login", inject: nil)
        )
        XCTAssertEqual(provider.configs.last?.initialInput, "codex login\n")
        XCTAssertNil(store.pendingPrompts[session.id])
    }
}
