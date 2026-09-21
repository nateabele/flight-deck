import XCTest
@testable import FlightDeck

/// **The gate every string Flight Deck types into a live agent stands behind.**
///
/// `SessionStore.injectionGate` now asks two sources rather than one. Whether the session is
/// up at all is a durable fact the agent reports through its own lifecycle
/// (`ComposerReadiness`, fed by claude's hook plugin and codex's rollout evidence); whether a
/// dialog is covering the composer *right now* is a property of this instant, which only the
/// screen knows (`AgentTextChannel.isKnownNonComposer`). `.unknown` — nothing has reported —
/// takes exactly the path it took before any of this existed, `hasComposerBox`.
///
/// Every screen used below is either a verbatim capture from `Fixtures/Claude/` or an inline
/// string this file labels as synthetic. Nothing hand-authored goes into `Fixtures/`.
@MainActor
final class SessionStoreInjectionGateTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Answers `thread/name/set` so a codex tab can be created at all. Same stub as
    /// `PhonePromptDispatchTests`, which is where the codex bare-shell case was pinned for the
    /// `.unknown` arm.
    private final class ScriptedCodexTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// **A synthetic bare shell — deliberately inline, not a fixture.** `Fixtures/` holds
    /// verbatim captures only. What matters about this string is exactly what a real shell
    /// prompt has and a composer does not: a `❯` that `InputBar.read` locks onto perfectly
    /// happily, with no `─` rule above it and none closing its run. `hasComposerBox` therefore
    /// refuses it, while `isKnownNonComposer` finds nothing to veto — which is precisely why a
    /// tab whose agent has died must not be left reading `.live`.
    private let bareShell = """
        ~/Projects/flight-deck on master
        ❯
        """

    private func screen(_ name: String) throws -> String {
        try TimelineFixtureTests.text("\(name).captured", in: "Claude")
    }

    /// Same shape as `PhonePromptQueueTests.makeStore`: a claude tab whose injection settles
    /// synchronously, so each test reads as straight-line code. The registry row is what
    /// anchors the tab — `testADeadAgentProcessResetsReadinessToUnknown` below takes it away
    /// again, which is the only way a tab's anchor is ever lost.
    private func makeStore() -> (SessionStore, SpyInjector, UUID, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.statusRootOverride = projectsRoot
        store.promptLifecycleSink = { _ in }
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, .idle, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id, session.pinnedConversationID)
    }

    // MARK: - `.live`

    /// The ordinary case the whole design exists to make cheap: the agent said it is up and
    /// the screen shows no dialog, so the text is typed — without `hasComposerBox` ever being
    /// consulted.
    func testLiveAndNoDialogInjects() throws {
        let (store, spy, id, _) = makeStore()
        store.apply(.lifecycle(.live), to: id)
        spy.viewportOverride = try screen("idle-empty-box")

        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertEqual(spy.sent, ["ship it"], "a live session with a clear screen takes it now")
        XCTAssertNil(store.promptQueue[id], "typed, so nothing waits")
    }

    /// **The veto, and it is the only dialog defence there is.** Hook events cannot detect a
    /// dialog — denying a permission prompt with Esc fires no hook at all — so were this
    /// screen check to pass, Flight Deck would press Return at a select list and PICK AN
    /// OPTION on the user's behalf.
    func testLiveButDialogOnScreenRefuses() throws {
        let (store, spy, id, _) = makeStore()
        store.apply(.lifecycle(.live), to: id)
        spy.viewportOverride = try screen("permission-bash")

        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertTrue(spy.events.isEmpty, "nothing may be typed at a dialog")
        XCTAssertNotNil(store.promptQueue[id], "held, not discarded")
    }

    /// **An unreadable screen is a refusal on the `.live` path, not merely "no dialog
    /// recognised".**
    ///
    /// `isKnownNonComposer` fails OPEN on a nil viewport by design — a predicate that must
    /// recognise a dialog has to answer "unsure" as "no veto", or a transient read failure
    /// looks exactly like a dialog and drops the message. That was safe only while the legacy
    /// path stood behind it: `hasComposerBox` independently fails CLOSED on nil. Once `.live`
    /// bypasses `hasComposerBox`, a session whose screen cannot be read would have no screen
    /// gate at all and would be typed into blind, so the gate reads the viewport itself.
    ///
    /// **Asserted at the gate, not only at the transcript, and that is the whole point of the
    /// seam.** Every channel's `submit` also refuses an unreadable screen today, so "nothing
    /// was typed" is true either way and cannot tell a gate that fails closed from one that
    /// merely got lucky downstream. Both are checked: the verdict, which discriminates, and
    /// the transcript, which is what the user would actually suffer.
    func testLiveWithAnUnreadableViewportRefuses() {
        let (store, spy, id, _) = makeStore()
        store.apply(.lifecycle(.live), to: id)
        spy.viewportIsReadable = false

        XCTAssertFalse(store.injectionGateAdmitsForTesting(id),
                       "the gate itself must refuse, not lean on the channel behind it")

        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertTrue(spy.events.isEmpty,
                      "a screen that cannot be read is not a screen to type at")
        XCTAssertNotNil(store.promptQueue[id], "held, not discarded")
    }

    // MARK: - `.absent`

    /// The agent said its session ended. The screen is the one that injects on every other
    /// path in this file, which is the point: `.absent` refuses on the lifecycle alone.
    ///
    /// The brief words this "refuses without reading the viewport", and the gate does return
    /// before any read — but that cannot be asserted through `submitPrompt`, because
    /// `logPromptTyping` reads the viewport for its `composer=` diagnostic before `inject` is
    /// ever reached. Pinning the screen to a known-good composer proves the same thing that
    /// matters: the refusal owes nothing to what is on it.
    func testAbsentRefuses() throws {
        let (store, spy, id, _) = makeStore()
        store.apply(.lifecycle(.absent), to: id)
        spy.viewportOverride = try screen("idle-empty-box")

        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertTrue(spy.events.isEmpty, "the agent reported its session gone")
        XCTAssertNotNil(store.promptQueue[id], "held, not discarded")
    }

    // MARK: - `.unknown`, the migration guarantee

    /// A session that never reported takes exactly today's path, and today's path injects
    /// into a real composer.
    func testUnknownUsesTheLegacyGrammar() throws {
        let (store, spy, id, _) = makeStore()
        XCTAssertEqual(store.composerReadiness(for: id), .unknown, "the premise")
        spy.viewportOverride = try screen("idle-empty-box")

        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertEqual(spy.sent, ["ship it"], "unchanged from before the readiness gate existed")
        XCTAssertNil(store.promptQueue[id])
    }

    /// The other half of that guarantee, and the one that carries the risk: a bare shell
    /// carries no composer, so the legacy grammar refuses it. Typing here would RUN the text
    /// as a command rather than send it to an agent.
    func testUnknownWithABareShellRefuses() {
        let (store, spy, id, _) = makeStore()
        XCTAssertEqual(store.composerReadiness(for: id), .unknown, "the premise")
        spy.viewportOverride = bareShell

        store.submitPrompt("ship it", token: UUID(), to: id)

        XCTAssertTrue(spy.events.isEmpty, "a shell prompt is not a composer")
        XCTAssertNotNil(store.promptQueue[id], "held, not discarded")
    }

    // MARK: - A dead agent must stop reading `.live`

    /// **Neither agent reliably signals session death, so the store has to notice by itself.**
    ///
    /// `SessionReaper`'s `SIGHUP → SIGTERM → SIGKILL` escalation means claude's `SessionEnd`
    /// hook often never fires, and codex has no session-end rollout record at all. A tab whose
    /// agent has died would therefore keep reading `.live` forever — and `.live` plus "no
    /// dialog recognised" would type into the bare shell left behind, which is strictly worse
    /// than the behaviour this replaces, since a bare shell carries no dialog markers for the
    /// veto to catch. The liveness signal is the status-registry anchor: `SessionStatusWatcher`
    /// drops rows whose pid is dead, so a tab that HAD an anchor and lost it is a tab whose
    /// claude is gone.
    /// **Driven through a rename rather than a phone prompt, deliberately.** `submitPrompt`
    /// refuses a tab with no status at all (`.notRunning`) before the gate is ever consulted,
    /// so a dead claude's queue never reaches `inject` down that path. A rename does: it is a
    /// direct user action on the sidebar, it consults no status, and it shares this exact gate
    /// through `injectRename`. So the rename path — along with `pendingPrompts`' restore-time
    /// "Keep going" — is where a stale `.live` would really have typed into a bare shell.
    func testADeadAgentProcessResetsReadinessToUnknown() {
        let (store, spy, id, _) = makeStore()
        store.apply(.lifecycle(.live), to: id)
        XCTAssertEqual(store.composerReadiness(for: id), .live, "the premise")

        // The claude process exits; its status file goes with it, so the next scan carries no
        // row for this tab at all.
        store.applyRegistry([:])

        XCTAssertEqual(store.composerReadiness(for: id), .unknown,
                       "a tab whose agent is gone falls back to the legacy screen check")

        spy.viewportOverride = bareShell
        XCTAssertFalse(store.injectionGateAdmitsForTesting(id),
                       "and the legacy screen check refuses a bare shell")

        XCTAssertTrue(store.rename(id, to: "typed at a dead tab"))
        XCTAssertEqual(spy.events, [], "so a rename defers instead of running as a command")
    }

    /// **The same window, entered from the other side — and the reason the test is level
    /// rather than the anchor's falling edge.** A `claude` whose `SessionStart` is logged and
    /// which then dies before writing its status file is never anchored at all. An
    /// edge-triggered reset ("had an anchor, lost it") cannot fire for it, so the tab would
    /// keep `.live` permanently at a bare shell — and `ClaudeTextChannel.submit`'s only screen
    /// precondition is `InputBar.read` finding one `❯` row, which a shell prompt satisfies. A
    /// sidebar rename would then run `/rename foo` as a command. Sub-second to enter,
    /// unbounded once entered.
    func testADeathBeforeTheTabWasEverAnchoredIsAlsoCaught() {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.statusRootOverride = projectsRoot
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)

        // The hook was logged; the status file never was, because the process died first.
        store.apply(.lifecycle(.live), to: session.id)
        store.applyRegistry([:])

        XCTAssertEqual(store.composerReadiness(for: session.id), .unknown,
                       "never anchored is not the same as still alive")

        spy.viewportOverride = bareShell
        XCTAssertFalse(store.injectionGateAdmitsForTesting(session.id))
        XCTAssertTrue(store.rename(session.id, to: "not a shell command"))
        XCTAssertEqual(spy.events, [], "nothing runs at the shell")
    }

    /// **The boot window the level test costs, and the reason it is affordable.** A
    /// `SessionStart` logged before claude has written its status file is erased by the very
    /// next tick — which is safe (the tab falls back to the legacy screen grammar, exactly
    /// what it did before any of this existed) but would be permanent if the reset were
    /// one-way. `HookEventWatcher` emits only on a change and never forgets on its own, so
    /// without `resetComposerReadiness` clearing its memory too, the resumed agent's next
    /// event would fold to `.live`, compare equal to what the watcher still remembered, and
    /// never reach the store at all.
    func testAResetAlsoClearsTheHookWatchersMemoryOfTheSession() throws {
        let hookDirectory = projectsRoot.appendingPathComponent("hook-events", isDirectory: true)
        try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)

        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.statusRootOverride = projectsRoot.appendingPathComponent("status", isDirectory: true)
        store.hookEventDirectoryOverride = hookDirectory
        let session = store.newSession(in: tmp)

        // Built against an empty directory, so nothing already on disk is skipped as backlog.
        store.startStatusWatching()
        // Cast rather than widening the seam: `hookEventWatcherForTesting` is typed `AnyObject?`
        // on purpose, because its other caller only ever asserts identity across two sweeps.
        let watcher = try XCTUnwrap(store.hookEventWatcherForTesting as? HookEventWatcher)

        let log = hookDirectory.appendingPathComponent("events.ndjson")
        let start = """
            {"session_id":"\(session.pinnedConversationID.uuidString)","hook_event_name":"SessionStart"}

            """
        try start.write(to: log, atomically: true, encoding: .utf8)
        watcher.drain()
        XCTAssertEqual(watcher.rememberedReadinessForTesting(session.pinnedConversationID), .live,
                       "the premise: the watcher is now holding a fold for this session")

        store.applyRegistry([:])

        XCTAssertNil(watcher.rememberedReadinessForTesting(session.pinnedConversationID),
                     "a reset the watcher does not know about makes the reset one-way")
    }

    /// A live tab is not reset by an ordinary tick. Without this, the test above would also
    /// pass against an implementation that never resets anything at all.
    func testAnAnchoredTabKeepsItsReadinessAcrossTicks() {
        let (store, _, id, conversation) = makeStore()
        store.apply(.lifecycle(.live), to: id)

        store.applyRegistry([1: entry(conversation, .busy, cwd: tmp.path)])

        XCTAssertEqual(store.composerReadiness(for: id), .live, "still running, still live")
    }

    // MARK: - The deadlock this design was reworked to avoid

    /// **The case the whole design turns on.** Denying a permission prompt with Esc fires no
    /// hook whatsoever, so nothing would ever clear a dialog *state*. That is why readiness
    /// carries no `.dialog` case and the dialog is read off the screen instead: the refusal
    /// has to evaporate the instant the dialog does, with no event in between.
    ///
    /// The retry is the ordinary registry tick, which is what production runs — it carries
    /// activity and nothing else, so no lifecycle information passes between the refusal and
    /// the injection. Readiness is asserted unmoved on both sides of it.
    func testATabStaysInjectableAfterADeniedPermissionPrompt() throws {
        let (store, spy, id, conversation) = makeStore()
        store.apply(.lifecycle(.live), to: id)

        spy.viewportOverride = try screen("permission-bash")
        store.submitPrompt("ship it", token: UUID(), to: id)
        XCTAssertTrue(spy.events.isEmpty, "refused while the prompt is up")
        XCTAssertNotNil(store.promptQueue[id], "held")

        // Esc. Nothing reports anything; the only thing that changed is the screen.
        spy.viewportOverride = try screen("idle-empty-box")
        XCTAssertEqual(store.composerReadiness(for: id), .live, "and readiness never moved")

        store.applyRegistry([1: entry(conversation, .idle, cwd: tmp.path)])

        XCTAssertEqual(store.composerReadiness(for: id), .live, "still never moved")
        XCTAssertEqual(spy.sent, ["ship it"], "the held prompt goes — the tab never wedged")
        XCTAssertNil(store.promptQueue[id], "nothing left waiting")
    }

    // MARK: - The codex half of the asymmetry

    /// **Codex is the adapter with no liveness reset, so the invariant that makes that safe
    /// must be pinned rather than argued in a comment.**
    ///
    /// `pinResolutions` filters on `hasStatusRegistry`, so a codex tab never enters the loop
    /// that resets readiness — it keeps whatever its rollout last reported, `.live` included,
    /// long after its TUI has gone. What protects it is a second line claude does not have:
    /// `CodexTextChannel.submit` opens with `guard let bar = composer(injector)`, and
    /// `composer(_:)` requires codex's `›` marker AND a `model · mode · cwd` footer within
    /// three rows beneath it — which no shell draws. The existing codex bare-shell tests
    /// (`PhonePromptDispatchTests`, `AgentTextChannelTests`) all run at `.unknown`, so they
    /// exercise the legacy arm and say nothing about this one.
    ///
    /// The screen is claude's `❯`, which is what a codex tab fallen back to a bare shell
    /// actually shows, and which `CodexTextChannel` must refuse for a second reason too: it is
    /// not even codex's glyph.
    func testACodexTabReportedLiveStillTypesNothingAtABareShell() async throws {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        store.promptLifecycleSink = { _ in }
        // The fixture's rollout path does not exist on disk; stubbed true so creation reaches
        // success rather than tripping `prepare`'s history-contract check.
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedCodexTransport()), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        guard case .success(let id) = await store.createSession(agent: .codex, in: tmp.path) else {
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle, waitingFor: nil)])
        spy.events.removeAll()

        // Codex's rollout said the TUI was alive, and nothing will ever say otherwise: there
        // is no session-end rollout record, and no registry tick visits a codex tab.
        store.apply(.lifecycle(.live), to: id)
        spy.viewportOverride = bareShell
        XCTAssertEqual(store.composerReadiness(for: id), .live,
                       "the premise: no reset reaches a codex tab")

        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .queued)
        XCTAssertTrue(spy.events.isEmpty,
                      "codex's own composer precondition refuses a shell whatever the gate says")

        XCTAssertTrue(store.rename(id, to: "renamed at a dead codex"))
        XCTAssertEqual(spy.events, [], "and the rename modal is gated the same way")
    }

    // MARK: - Ordering within a registry tick

    /// **The reset runs in `applyRegistry`'s body; the three flushes run in its `defer`.** So
    /// on the very tick that detects a death, the flushes already read `.unknown`. That
    /// closes the window where a prompt queued while the agent was alive would be typed into
    /// the bare shell it left behind — and nothing else pins it, so a refactor moving the
    /// reset into the `defer` would pass every other test in this file while reopening it.
    func testTheReadinessResetRunsBeforeTheTickFlushesTheQueue() throws {
        let (store, spy, id, _) = makeStore()
        store.apply(.lifecycle(.live), to: id)

        // Queued while alive and held by the veto, so it is still in the queue when the agent
        // dies — which is the only way to be waiting at the moment the tick notices.
        spy.viewportOverride = try screen("permission-bash")
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .queued)
        XCTAssertTrue(spy.events.isEmpty, "the premise: held, not typed")

        // The agent dies. Its dialog goes with it; what is left is the shell underneath.
        spy.viewportOverride = bareShell
        store.applyRegistry([:])

        XCTAssertEqual(spy.events, [],
                       "the flush in the defer must see .unknown, not the .live it replaced")
        XCTAssertNotNil(store.promptQueue[id], "so the entry is still held, not run as a command")
    }

    // MARK: - `/rename` shares this gate

    /// `injectRename` calls `injectionGate` once before driving its modal, and claude's
    /// `/rename` goes through `inject` outright — so a readiness gate that got this wrong
    /// would break every sidebar rename, which an earlier change in this area really did.
    func testARenameUnderLiveReadinessStillTypes() throws {
        let (store, spy, id, _) = makeStore()
        store.apply(.lifecycle(.live), to: id)
        spy.viewportOverride = try screen("idle-empty-box")

        XCTAssertTrue(store.rename(id, to: "renamed under live"))

        XCTAssertEqual(spy.sent, ["/rename renamed under live"], "renames are not special-cased")
    }
}
