import XCTest
@testable import FlightDeck

/// **The one question, and the two places that never asked it.**
///
/// `AgentAdapter.textChannel` answers "may a message be typed into this agent's live terminal
/// at all", and a `nil` there IS the refusal. `SessionStore` consults it at three sites. One
/// of them replaced an `agent == .claude` name check and is pinned elsewhere —
/// `PhonePromptDispatchTests` for `submitPrompt` — which is what proves the rewrite changed
/// no behaviour. The other two had **no gate of any kind**, and are what this file exists
/// for:
///
/// - `restore`'s auto-resume gate queued `"Keep going"` for *any* tab persisted in a resumable
///   activity, and codex persists `.busy` — `CodexEventMapper` emits it on `task_started`.
/// - `inject`, the funnel that queue drains into, typed it at whatever pty answered.
///
/// **Two tests, not one.** "Nothing was queued" and "nothing was typed" are different facts
/// with different guards behind them, and a test that only checked the queue would stay green
/// while the injector still ran. So the injector's refusal is proved through
/// `queuePendingPromptForTesting`, which reaches it without the queue gate above it.
///
/// **Every fixture that must refuse is one that could otherwise type.** The shared
/// `SpyInjector` defaults `renderedRows = ["❯"]` — the glyph `InputBar.read` locks onto, and
/// one a bare shell prompt draws too — and its status is set idle, so without the guard the
/// text goes out. The claude twin beside each codex test is what proves that, and is what
/// stops a mutation that broke injection altogether from reading as a passing gate.
@MainActor
final class AgentTextChannelTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private final class MemoryPreferences: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Enough of an app-server to create and settle a thread, so a codex tab exists without
    /// `codex` ever being spawned — the mechanism `CodexResumeTests` documents, and the only
    /// thing keeping the committed suite off the user's real threads.
    private final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(Self.thread)","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            case "thread/read":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(Self.thread)","name":"t","status":{"type":"idle"},"path":"/r/x.jsonl","cwd":"/w/a"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }

        static let thread = "01a01269-baa6-7493-8d15-8fa21bcb602b"
    }

    private struct CodexTabUnavailable: Error {}

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    // MARK: - The capability itself

    /// Read through `AgentID`, but *answered* by the adapters. Both shipped agents now have a
    /// channel; what this pins is that the enum forwards the adapter's answer rather than
    /// deciding a capability itself, so the two can never disagree.
    func testTheEnumForwardsEachAdaptersOwnChannel() {
        XCTAssertNotNil(AgentID.claude.textChannel)
        XCTAssertNotNil(ClaudeAdapter.textChannel)
        XCTAssertNotNil(AgentID.codex.textChannel)
        XCTAssertNotNil(CodexAdapter.textChannel)
    }

    /// The channels are not interchangeable, and this is what stops the capability question
    /// from quietly becoming "any agent can be typed into". Each reads its own marker glyph;
    /// pointed at the other's screen, each finds nothing.
    func testEachChannelReadsOnlyItsOwnAgentsComposer() {
        let codexScreen = "› Ask Codex to do anything\n\n  gpt-5.6-sol default · /tmp/w"
        let claudeScreen = "❯ \u{00A0}"
        XCTAssertNil(InputBar.read(fromViewport: codexScreen, marker: InputBar.claudeMarker))
        XCTAssertNil(InputBar.read(fromViewport: claudeScreen, marker: InputBar.codexMarker))
    }

    // MARK: - restore: nothing is queued

    /// Two tabs, one restore, both persisted `busy` — so the only difference between the tab
    /// that gets a prompt and the tab that does not is the agent.
    private func restoreBothAgents() -> (SessionStore, codex: UUID, claude: UUID, SpyInjector) {
        let codexID = UUID()
        let claudeID = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: codexID, title: "c", workingDirectory: tmp.path,
                      pinnedConversationID: UUID(uuidString: ScriptedTransport.thread)!,
                      activity: "busy", agent: .codex, transcriptPath: "/r/x.jsonl"),
                .init(id: claudeID, title: "a", workingDirectory: tmp.path, activity: "busy"),
            ],
            selectedSessionID: nil, sessionCounter: 2
        )
        let preferences = PreferencesStore(persistence: MemoryPreferences())
        preferences.autoResumesRunningSessions = true
        let store = SessionStore(
            provider: StubProvider(), persistence: persistence, preferences: preferences
        )
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl`: restoring a codex tab builds a
        // `CodexStack`, whose name watcher would otherwise tail it.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        // Keyed to the account the tab actually resolves to. A `PreferencesStore` seeds the
        // built-in accounts, so this is NOT nil here — an override filed under the wrong key
        // is silently not found, and for codex "not found" means spawning a real app-server.
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport())),
            for: .codex, account: preferences.resolvedAccountID(for: .codex, in: nil)
        )
        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        return (store, codexID, claudeID, spy)
    }

    /// **Codex now queues a resume prompt like claude, and the safety moved rather than
    /// vanished.** Giving codex a text channel switches on all three sites at once — that is
    /// the point of one capability question — so the auto-resume gate opens too.
    ///
    /// What stops a stray `"Keep going"` is no longer "codex is refused by name"; it is
    /// `CodexTextChannel` refusing a screen that is not codex's composer. The shared
    /// `SpyInjector` renders `❯`, claude's glyph, with no codex status line — so the prompt
    /// is queued and still nothing is typed. That is the property worth pinning, because it
    /// is the one that protects a codex tab sitting at a bare shell.
    func testARestoredBusyCodexTabQueuesAResumePromptButNothingIsTypedAtANonCodexScreen() async {
        let (store, codexID, _, spy) = restoreBothAgents()
        XCTAssertEqual(store.pendingPrompts[codexID]?.text, SessionStore.resumePrompt,
                       "codex has a channel now, so the same gate that opens for claude opens here")

        await store.codexRestoreTask?.value

        // The tab's own launch goes to the shell through `sendToShell`, which never touches
        // `inject` — so the resume command is there and the prompt is NOT.
        XCTAssertEqual(spy.sent, ["codex resume \(ScriptedTransport.thread)"],
                       "a claude-shaped screen is not codex's composer; nothing may be typed into it")
    }

    /// The neighbour. A mutation that deletes the auto-resume gate outright kills this and not
    /// the test above — which is the difference between "codex is refused" and "nothing is
    /// ever queued", and the reason both are asserted from one restore.
    func testARestoredBusyClaudeTabInTheSameRestoreStillQueuesOne() async {
        let (store, _, claudeID, _) = restoreBothAgents()
        XCTAssertEqual(store.pendingPrompts[claudeID]?.text, SessionStore.resumePrompt)
        await store.codexRestoreTask?.value
    }

    // MARK: - inject: nothing is typed

    /// One live tab of `agent`, idle, with a spy that can be typed into.
    private func liveTab(agent: AgentID) async throws -> (SessionStore, UUID, SpyInjector) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }

        let id: UUID
        if agent == .codex {
            // No `PreferencesStore` on this store, so every tab resolves to the nil account —
            // the key `createSession` will look this up under. `/r/x.jsonl` above does not
            // exist on disk, so `rolloutExists` is stubbed true rather than left at the
            // production default.
            store.overrideAdapter(
                CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport()), rolloutExists: { _ in true }),
                for: .codex, account: nil
            )
            guard case .success(let created) =
                await store.createSession(agent: .codex, in: tmp.path)
            else {
                XCTFail("codex tab creation must succeed against a scripted transport")
                throw CodexTabUnavailable()
            }
            id = created
        } else {
            id = store.newSession(in: tmp).id
        }
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        spy.events.removeAll()
        return (store, id, spy)
    }

    /// **The live bug, at the funnel rather than at the queue.** The prompt is put in the
    /// queue directly, so the gate in `restore` cannot be what refuses it; everything
    /// `inject` reads is satisfied — idle status, a spy whose screen shows `❯` — so the only
    /// thing left to stop the paste is the capability guard.
    ///
    /// `events`, not `sent`: the Ctrl+U goes out *before* any text, so a guard placed after
    /// the kill would still leave `sent` empty while having already cleared someone's draft.
    func testNothingIsTypedIntoACodexTabEvenWithAPromptQueued() async throws {
        let (store, id, spy) = try await liveTab(agent: .codex)

        store.queuePendingPromptForTesting(SessionStore.resumePrompt, for: id)
        store.flushPendingResumePromptsForTesting()

        XCTAssertTrue(spy.events.isEmpty, "not one keystroke, not even the kill")
        XCTAssertNotNil(store.pendingPrompts[id], "refused for now, not retired as sent")
    }

    /// The twin, and it does two jobs: it proves the fixture above could have typed, and it
    /// proves `queuePendingPromptForTesting` is not a no-op. If a mutation to the seam left
    /// both tests green, the seam — not the guard — is what those tests were measuring.
    func testTheSameQueuedPromptIsTypedIntoAClaudeTab() async throws {
        let (store, id, spy) = try await liveTab(agent: .claude)

        store.queuePendingPromptForTesting(SessionStore.resumePrompt, for: id)
        store.flushPendingResumePromptsForTesting()

        XCTAssertEqual(spy.sent, [SessionStore.resumePrompt])
        XCTAssertEqual(spy.events.last, .ret, "Return must arrive after the paste closes")
        XCTAssertNil(store.pendingPrompts[id], "typed, so retired")
    }
}
