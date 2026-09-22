import XCTest
@testable import FlightDeck

/// **The regression `maintenanceTick` exists to close.** `applyRegistry`'s `defer` used to be
/// the only place a queued phone prompt, a deferred rename, or anything else parked there ever
/// got a retry — and it only ever runs from a claude registry scan. `startStatusWatching` and
/// `startWatching(tabID:)` both gate the watcher that drives that scan on `hasStatusRegistry`,
/// which codex answers `false`. So a fleet with a codex tab and no claude tab anywhere never
/// called `applyRegistry` at all, and anything waiting on that tick starved forever.
///
/// This file proves the fix by construction: a store with a codex tab and NO claude tab
/// anywhere — the one shape that could never have passed by riding a claude tick — with a
/// phone-sent prompt that is typed only once `maintenanceTickForTesting()` runs.
@MainActor
final class SessionStoreMaintenanceTickTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Enough of an app-server to create and settle a codex thread with no `codex` process
    /// ever spawned — same shape as `AgentTextChannelTests.ScriptedTransport`.
    private final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(Self.thread)","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
        static let thread = "01a01705-bd49-7b70-a0a1-4514d4bda5dd"
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

    /// One live codex tab, idle, with no claude tab anywhere in the store — copied from
    /// `AgentTextChannelTests.liveTab(agent:)`, narrowed to the one agent this file is about.
    private func makeStoreWithASingleCodexTab() async throws -> (SessionStore, UUID, SpyInjector) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport()), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )
        guard case .success(let id) = await store.createSession(agent: .codex, in: tmp.path) else {
            XCTFail("codex tab creation must succeed against a scripted transport")
            throw CodexTabUnavailable()
        }
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        spy.events.removeAll()
        // `maintenanceTick` is where this feature's new `apiErrors` writes happen, so the
        // store that drives it runs under `FleetReplicator`'s drift assertion too — see that
        // class's comment on why a new mutation site has to bring the check with it. The
        // returned replicator is unused here on purpose: no test in this file asserts on
        // emissions, it is the assertion itself that is wanted.
        _ = attachedReplicator(to: store)
        return (store, id, spy)
    }

    /// Codex's real idle composer shape — one row, the placeholder, and the status-line footer
    /// `CodexTextChannel.hasFooter` requires directly beneath it. Same screen
    /// `AgentTextChannelTests.testASecondPromptArrivingBetweenCodexsTwoSettleHopsIsQueuedNotTyped`
    /// uses.
    private static let codexComposerViewport =
        "› Ask Codex to do anything\n\n  gpt-5.6-sol default · /tmp/work"

    /// A codex-only fleet gets no `applyRegistry` tick at all — see the file's own doc comment.
    /// This is the regression guard.
    ///
    /// The composer starts on a genuine MULTI-ROW draft, the same shape
    /// `PhonePromptQueueTests.makeBusyStoreThatHoldsTheQueue` uses to hold a claude queue: a
    /// `CodexTextChannel` composer is only ever one row, so `submitPrompt`'s own eager inline
    /// flush legitimately refuses to type here. That refusal is what makes the later assertion
    /// about the TICK specifically, and not about submit's own immediate retry.
    ///
    /// Only once the draft clears to codex's real idle composer and `maintenanceTickForTesting`
    /// runs does the queued prompt go out.
    func testACodexOnlyFleetStillTypesAQueuedPrompt() async throws {
        let (store, id, spy) = try await makeStoreWithASingleCodexTab()
        spy.viewportOverride = "› a multi\n  row draft\n\n  gpt-5.6-sol default · /tmp/work"

        XCTAssertEqual(store.submitPrompt("hello", token: UUID(), to: id), .queued)
        XCTAssertTrue(spy.events.isEmpty, "a multi-row draft cannot be typed around; nothing may be typed")

        spy.viewportOverride = Self.codexComposerViewport
        store.maintenanceTickForTesting()

        XCTAssertEqual(spy.sent, ["hello"])
        XCTAssertEqual(spy.events.last, .ret, "Return must arrive after the paste closes")
        XCTAssertNil(store.promptQueue[id], "typed, so retired")
    }

    /// The wiring that makes the fix above real in production, mirroring
    /// `DisplayWakeTests.testTheRealWakerIsWiredIn`: that test proves a *stored property*
    /// survives `convenience init`; this proves a *registration* does, for a line with no
    /// property to inspect. Deleting `clock.add(self) { ... }` from `convenience init` is
    /// otherwise undetectable by this file — `testACodexOnlyFleetStillTypesAQueuedPrompt`
    /// above drives `maintenanceTick()` through the `maintenanceTickForTesting()` seam, which
    /// bypasses that line entirely, so every other test here would stay green.
    func testTheMaintenanceTickIsRegisteredOnTheRealClock() {
        let store = SessionStore(ghostty: nil, persistence: nil)
        XCTAssertTrue(store.isRegisteredForMaintenanceTickTesting)
    }
}
