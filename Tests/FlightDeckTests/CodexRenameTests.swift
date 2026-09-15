import XCTest
@testable import FlightDeck

/// Sidebar → codex. The direction `SessionStore.rename`'s `.codex` arm exists to serve, and
/// the one nothing covered: every `thread/name/set` assertion in this suite belongs to
/// `prepare`, so a rename that never reached codex would have left all of them green.
///
/// **That direction has two halves, and this file now covers both.** The wire call renames
/// the thread's metadata; it cannot reach the attached `codex resume` TUI, which owns the
/// screen and goes on drawing the old name. So the arm also types the rename at codex's own
/// composer, through the funnel claude's rename already used — and the tests below assert
/// against the real captured screens, never a modal anybody authored.
///
/// It matters that this is silent when it breaks. Neither half alerts: the wire call is a
/// `Task` whose failure only reaches `SessionStore.renameLogger.error` — deliberately
/// fire-and-forget, because a refused rename must not block the user's edit or pop an alert —
/// and the typed half likewise only logs when codex refuses the modal. So the sole evidence a
/// rename never landed is codex's name diverging from the sidebar's, which the next
/// `CodexNameWatcher` tick then papers over by pushing codex's stale name back UP into the
/// sidebar. Up-propagation working is exactly what makes down-propagation failing hard to see.
@MainActor
final class CodexRenameTests: XCTestCase {
    private var retained: [AnyObject] = []
    private var projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-rename-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectsRoot)
        retained.removeAll()
        super.tearDown()
    }

    func testRenamingACodexTabSendsThreadNameSetWithTheSanitizedTitle() async throws {
        let (store, transport) = try await makeCodexTab()
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first)

        XCTAssertTrue(store.rename(tab.id, to: "renamed from the sidebar"))
        try await settle(transport, untilMethodCountExceeds: 4)

        XCTAssertEqual(transport.methods.last, "thread/name/set",
                       "the sidebar's rename must reach codex, not stop at the local title")
        XCTAssertEqual(transport.lastRenameName, "renamed from the sidebar")
        XCTAssertEqual(transport.lastRenameThreadID, transport.threadID.lowercased(),
                       "renaming must target the thread codex named, not the tab's own id")
    }

    /// The local title changes either way — that is the method's stated promise — so a test
    /// that only checked the title would pass against a completely unwired `.codex` arm.
    func testTheLocalTitleAloneIsNotEvidenceTheAgentWasTold() async throws {
        let (store, transport) = try await makeCodexTab()
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first)

        XCTAssertTrue(store.rename(tab.id, to: "sidebar only"))
        try await settle(transport, untilMethodCountExceeds: 4)

        XCTAssertEqual(store.repos.flatMap(\.sessions).first?.title, "sidebar only")
        XCTAssertTrue(transport.methods.contains("thread/name/set"),
                      "title updated locally but codex never told — the exact silent divergence "
                      + "this arm exists to prevent")
    }

    /// `rename` returns true and sends nothing when the name is unchanged: re-sending is not
    /// merely wasted work, it interrupts a running agent to tell it what it already knows.
    func testRenamingToTheSameNameTellsCodexNothing() async throws {
        let (store, transport) = try await makeCodexTab()
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first)
        let creationCalls = transport.methods.count

        XCTAssertTrue(store.rename(tab.id, to: tab.title),
                      "an unchanged name is accepted, not rejected")
        try await yieldAWhile()

        XCTAssertEqual(transport.methods.count, creationCalls,
                       "no name/set for a name codex already has")
    }

    // MARK: - Typing the rename at the pty

    /// **The headline: a sidebar rename reaches the TUI, not just the wire.** Both stages of
    /// codex's modal are typed in one exact sequence — `/rename`⏎ to open it, the
    /// field-clearing kill, then the name⏎ to commit — and the `thread/name/set` belt still
    /// goes out alongside. This is the assertion the whole bug reduces to: before this, the
    /// tab kept drawing the old name and `CodexNameWatcher` pushed it back up a tick later.
    func testRenamingACodexTabTypesBothStagesOfTheModal() async throws {
        let spy = SpyInjector()
        let tab = try await makeCodexTab(injector: spy)
        spy.script(try renameScreens())

        XCTAssertTrue(tab.store.rename(tab.id, to: "renamed at the pty"))

        XCTAssertEqual(spy.events,
                       [.killLine, .text("/rename"), .ret,
                        .killLine, .text("renamed at the pty"), .ret],
                       "the rename must reach the attached TUI, not stop at the wire")
        XCTAssertNil(tab.store.pendingRenamesForTesting[tab.id],
                     "committed, so the entry is retired rather than retried")

        try await settle(tab.transport, untilMethodCountExceeds: 4)
        XCTAssertEqual(tab.transport.methods.last, "thread/name/set",
                       "typing is the braces; the wire call is still the belt")
    }

    /// **An ABORT is not a deferral, and the difference is what stops an unretirable queue.**
    /// `/rename`⏎ was really typed and no modal came up, so our model of codex is wrong.
    /// Retrying that on every registry tick is the "queued `/rename` for a pty nothing would
    /// ever retire it from" hazard `SessionStore.rename`'s doc warns about. Retiring is safe
    /// only because `thread/name/set` went out unconditionally — the cost is a stale label.
    func testARenameThatOpensNoModalEscapesAndRetiresRatherThanRetrying() async throws {
        let spy = SpyInjector()
        let tab = try await makeCodexTab(injector: spy)
        spy.script([try viewport("tui-idle.captured")])   // never repaints into the modal

        XCTAssertTrue(tab.store.rename(tab.id, to: "never typed"))

        XCTAssertEqual(spy.events, [.killLine, .text("/rename"), .ret, .escape])
        XCTAssertFalse(spy.sent.contains("never typed"),
                       "no modal means the name must never reach the pty — it would be "
                       + "submitted to the model as a real prompt")
        XCTAssertNil(tab.store.pendingRenamesForTesting[tab.id],
                     "an abort retires the entry; only a deferral keeps it")
    }

    /// A rename is a slash command whose effect the user is watching for, so it waits for the
    /// box rather than queueing behind a running turn. Ported from
    /// `SessionRenameTests.testRenameDefersWhileTheSessionIsBusy`.
    func testRenameDefersWhileTheCodexTabIsBusy() async throws {
        let spy = SpyInjector()
        let tab = try await makeCodexTab(injector: spy)
        spy.script(try renameScreens())
        tab.store.applyRegistryForTesting([tab.id: SessionStatus(activity: .busy)])
        spy.events.removeAll()

        XCTAssertTrue(tab.store.rename(tab.id, to: "busy"))

        XCTAssertTrue(spy.events.isEmpty, "not one keystroke, not even the kill")
        XCTAssertEqual(tab.store.pendingRenamesForTesting[tab.id], "busy",
                       "a DEFERRAL keeps the entry for the retry tick")
    }

    /// `waiting` means a dialog is up: a Return there answers the dialog instead of
    /// submitting. Ported from `SessionRenameTests.testRenameDefersWhileTheSessionIsWaiting`.
    func testRenameDefersWhileTheCodexTabIsWaiting() async throws {
        let spy = SpyInjector()
        let tab = try await makeCodexTab(injector: spy)
        spy.script(try renameScreens())
        tab.store.applyRegistryForTesting([tab.id: SessionStatus(activity: .waiting)])
        spy.events.removeAll()

        XCTAssertTrue(tab.store.rename(tab.id, to: "waiting"))

        XCTAssertTrue(spy.events.isEmpty, "not one keystroke, not even the kill")
        XCTAssertEqual(tab.store.pendingRenamesForTesting[tab.id], "waiting")
    }

    /// Deferral is a delay, not a loss: the registry scan is the retry tick. Ported from
    /// `SessionRenameTests.testDeferredRenameInjectsOnceTheBarClears`.
    ///
    /// `applyRegistry([:])` rather than a fabricated row — for a codex tab the rows are
    /// irrelevant (see the fixture), and what is being exercised is the scan's `defer`, which
    /// flushes pending renames whether or not any status moved.
    func testADeferredCodexRenameDrainsOnTheNextRegistryScan() async throws {
        let spy = SpyInjector()
        let tab = try await makeCodexTab(injector: spy)
        spy.viewportIsReadable = false            // no readable composer: defer before typing

        XCTAssertTrue(tab.store.rename(tab.id, to: "later"))
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertEqual(tab.store.pendingRenamesForTesting[tab.id], "later")

        spy.viewportIsReadable = true
        spy.script(try renameScreens())
        tab.store.applyRegistry([:])

        XCTAssertEqual(spy.events,
                       [.killLine, .text("/rename"), .ret,
                        .killLine, .text("later"), .ret])
        XCTAssertNil(tab.store.pendingRenamesForTesting[tab.id])
    }

    /// One pending rename per tab, replaced rather than queued. Ported from
    /// `SessionRenameTests.testASecondRenameReplacesThePendingOne`.
    func testASecondCodexRenameReplacesThePendingOne() async throws {
        let spy = SpyInjector()
        let tab = try await makeCodexTab(injector: spy)
        spy.viewportIsReadable = false

        XCTAssertTrue(tab.store.rename(tab.id, to: "first"))
        XCTAssertTrue(tab.store.rename(tab.id, to: "second"))

        spy.viewportIsReadable = true
        spy.script(try renameScreens())
        tab.store.applyRegistry([:])

        XCTAssertEqual(spy.sent, ["/rename", "second"],
                       "the superseded name is never typed, and never typed in turn")
        XCTAssertEqual(tab.store.title(of: tab.id), "second")
    }

    /// **The no-TUI path must not regress.** Typing is additive: with no injector attached
    /// there is nothing to type into, and the wire call is the only thing that can rename the
    /// thread at all. The entry stays pending — a deferral, not an abort.
    func testTheWireCallStillFiresWithNoAttachedInjector() async throws {
        let (store, transport) = try await makeCodexTab()
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first)

        XCTAssertTrue(store.rename(tab.id, to: "no tui attached"))
        try await settle(transport, untilMethodCountExceeds: 4)

        XCTAssertEqual(transport.methods.last, "thread/name/set",
                       "the wire call is what renames a thread with no TUI attached")
        XCTAssertEqual(store.pendingRenamesForTesting[tab.id], "no tui attached",
                       "nothing was typed, so the entry is deferred rather than retired")
    }

    // MARK: - Fixtures

    private struct CodexTab {
        let store: SessionStore
        let transport: RenameTransport
        let id: UUID
    }

    /// The no-injector tab: a codex thread with no readable TUI behind it, which is the
    /// shape the three wire tests above were written against.
    private func makeCodexTab() async throws -> (SessionStore, RenameTransport) {
        let tab = try await makeCodexTab(injector: nil)
        return (tab.store, tab.transport)
    }

    private func makeCodexTab(injector spy: SpyInjector?) async throws -> CodexTab {
        let provider = StubProvider()
        retained.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl` — `runtime(for: .codex)` still
        // builds a real `CodexStack` whose watcher would otherwise tail the user's home.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")

        let transport = RenameTransport()
        retained.append(transport)
        // `/r/t.jsonl` does not exist; stubbed true so creation exercises the real four-call
        // sequence rather than `prepare`'s history-contract guard.
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: transport), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )

        // The injector wiring `SessionRenameTests.makeStore` uses, so a rename runs as
        // straight-line code instead of across a 120ms settle.
        if let spy {
            retained.append(spy)
            store.injectorOverride = spy
            store.injectionSettle = { $0() }
        }

        let result = await store.createSession(agent: .codex, in: projectsRoot.path)
        guard case .success(let id) = result else {
            throw XCTSkip("codex tab creation failed in fixture: \(result)")
        }

        // **`applyRegistryForTesting`, NOT `applyRegistry([1: entry(…)])`.** The claude-shaped
        // registry row that `SessionRenameTests` seeds with cannot give a codex tab a status:
        // `applyRegistry` skips every agent whose `hasStatusRegistry` is false and re-uses
        // whatever `statuses` already held, deliberately, because a scan of `claude`
        // processes can neither confirm nor refute a codex thread. Seeding through that path
        // would leave `statuses[id]` nil, and `inject`'s activity gate would then refuse every
        // rename below for a reason that has nothing to do with what these tests measure.
        // `.idle` is what `startWatching` seeds a real codex tab with at attachment.
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        spy?.events.removeAll()   // ignore anything emitted at creation
        return CodexTab(store: store, transport: transport, id: id)
    }

    /// A verbatim captured codex screen. Same loader as `CodexTextChannelTests`, and for the
    /// same reason: the store must be driven against what codex actually printed.
    private func viewport(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: CodexRenameTests.self).url(
                forResource: name, withExtension: "txt", subdirectory: "Fixtures/Codex"
            ),
            "missing capture \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Codex's composer, then the `/rename` modal it repaints into — the two screens a
    /// successful drive walks through, advancing on each Return.
    private func renameScreens() throws -> [String] {
        [try viewport("tui-idle.captured"), try viewport("tui-rename-modal.captured")]
    }

    /// The rename arm is `Task { … }`, so the call returns before the request is written.
    /// Polls rather than sleeping a fixed interval, and never uses `wait(for:)` — on a
    /// `@MainActor` test that deadlocks against the very actor the Task needs.
    private func settle(
        _ transport: RenameTransport,
        untilMethodCountExceeds count: Int,
        ticks: Int = 200
    ) async throws {
        for _ in 0..<ticks {
            if transport.methods.count > count { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func yieldAWhile(ticks: Int = 50) async throws {
        for _ in 0..<ticks {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Records the rename payload as well as the method, so a test cannot pass on a
    /// `thread/name/set` that carried the wrong thread or the wrong name.
    private final class RenameTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        private(set) var lastRenameName: String?
        private(set) var lastRenameThreadID: String?
        let threadID = "01a01705-bd49-7b70-a0a1-4514d4bda5dd"

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            if method == "thread/name/set", let params = obj["params"] as? [String: Any] {
                lastRenameName = params["name"] as? String
                lastRenameThreadID = params["threadId"] as? String
            }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(threadID)","path":"/r/t.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }
}
