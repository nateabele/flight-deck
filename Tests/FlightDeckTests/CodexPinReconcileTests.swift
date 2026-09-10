import XCTest
@testable import FlightDeck

/// Following a codex tab to the thread it is actually driving.
///
/// The bug: a user types `codex` at a Flight Deck tab's shell, codex starts a brand-new
/// thread, and nothing tells the store. Claude's counterpart is registry-driven and codex has
/// no registry, so the session record stays pinned to a thread nobody is writing — measured
/// live as a 676-line conversation on screen against a one-line, three-day-old rollout in the
/// record, which is what the phone and the tab title were both reading.
///
/// Nothing here spawns `codex`. Every store is handed a `CodexAdapter` over a scripted
/// transport through `overrideAdapter`, the house pattern documented at the top of
/// `CodexResumeTests` — which is also what keeps the restore path from reaching `startCodex()`.
@MainActor
final class CodexPinReconcileTests: XCTestCase {
    // MARK: - Doubles

    /// A `thread/list` oracle keyed by the `cwd` it was asked about.
    ///
    /// Keyed by directory rather than answering one canned list, because the two guards that
    /// matter most — per-group `try?`, and passing the directory verbatim — are both about
    /// *which* directory was asked and what came back for it specifically.
    private final class ThreadListTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        /// Every `cwd` a `thread/list` carried, in order and unmodified. The assertion target
        /// for the exact-string-match trap: codex answers a non-matching `cwd` with an empty
        /// array and no error, so a normalised path is a silent no-op.
        private(set) var listed: [String] = []
        /// `thread/list` results, as raw entries, keyed by the `cwd` asked about.
        var threads: [String: [[String: Any]]] = [:]
        /// Directories whose `thread/list` answers with codex's own error shape. Task 3 does
        /// not collapse a remote error to `[]`, which is what makes "asked, and there are
        /// none" different from "could not ask".
        var failing: Set<String> = []

        func forgetRecording() {
            methods.removeAll()
            listed.removeAll()
        }

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            guard method == "thread/list" else {
                // Enough for `rebind` and the restore path's follow-up read: an empty `thread`
                // object is a thread that exists and has no name, so nothing here re-pins or
                // renames a tab behind the test's back.
                onLine?(#"{"id":\#(id),"result":{}}"#)
                return
            }
            let cwd = (obj["params"] as? [String: Any])?["cwd"] as? String ?? ""
            listed.append(cwd)
            guard !failing.contains(cwd) else {
                onLine?(#"{"id":\#(id),"error":{"code":-32600,"message":"app-server is gone"}}"#)
                return
            }
            let body: [String: Any] = ["id": id, "result": ["data": threads[cwd] ?? []]]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
            onLine?(String(decoding: data, as: UTF8.self))
        }
    }

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private final class NullProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private final class NullInjector: TextInjecting {
        func sendText(_ text: String) {}
        func sendReturn() {}
        func sendKillLine() {}
        func sendYank() {}
        func sendArrowDown() {}
        func sendArrowUp() {}
        func sendEscape() {}
        func readViewport() -> String? { nil }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// One `thread/list` entry, in the shape `CodexAdapter.threads` decodes.
    private func entry(
        _ id: UUID, updatedAt: Int, path: String? = "/r/live.jsonl", name: String? = nil
    ) -> [String: Any] {
        var raw: [String: Any] = ["id": id.uuidString.lowercased(), "updatedAt": updatedAt]
        if let path { raw["path"] = path }
        if let name { raw["name"] = name }
        return raw
    }

    // MARK: - Fixture

    private let stale = UUID(uuidString: "01a07927-0000-7000-8000-000000000001")!
    private let live = UUID(uuidString: "01a0878d-0000-7000-8000-000000000002")!
    private let other = UUID(uuidString: "01a0878d-0000-7000-8000-000000000003")!

    private var projectsRoot: URL!

    override func setUpWithError() throws {
        projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    /// A restored store holding `sessions`, wired to `transport`, with the restore path's own
    /// reconcile pass already spent.
    ///
    /// Restored rather than assembled, because the assertions below read state only the real
    /// paths produce: the watcher attachment `repinCodex` restarts, and the pins the restore
    /// path has already settled. The transport's recording is cleared afterwards so each test
    /// asserts against the pass it drives itself, not against restore's.
    private func makeStore(
        _ sessions: [SessionSnapshot.Entry], transport: ThreadListTransport
    ) async -> SessionStore {
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: sessions, selectedSessionID: sessions.first?.id, sessionCounter: sessions.count
        )
        let store = SessionStore(provider: NullProvider(), persistence: persistence)
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl`.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        store.injectorOverride = NullInjector()
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: transport), rolloutExists: { _ in true }),
            // No `PreferencesStore` on this store, so every tab resolves to the nil account.
            for: .codex, account: nil
        )
        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value
        transport.forgetRecording()
        return store
    }

    private func codexEntry(
        _ id: UUID, pinned: UUID, directory: String, title: String = "a", path: String = "/r/stale.jsonl"
    ) -> SessionSnapshot.Entry {
        .init(
            id: id, title: title, workingDirectory: "/w/a", transcriptDirectory: directory,
            pinnedConversationID: pinned, agent: .codex, transcriptPath: path
        )
    }

    // MARK: - 1. A newer thread wins

    /// The whole point. Everything the dead pin was feeding has to move together: the pin
    /// itself, the rollout path the watcher and the phone read, the attachment that was
    /// tailing the old file, and the tab's name.
    func testATabIsRepinnedToTheNewerThreadItIsActuallyDriving() async {
        let tabID = UUID()
        let t = ThreadListTransport()
        t.threads["/w/a"] = [
            entry(live, updatedAt: 2_000, path: "/r/live.jsonl", name: "the real conversation"),
            entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl", name: "a"),
        ]
        let store = await makeStore(
            [codexEntry(tabID, pinned: stale, directory: "/w/a")], transport: t
        )

        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: tabID), live)
        let session = store.repos.flatMap(\.sessions).first { $0.id == tabID }
        XCTAssertEqual(session?.transcriptPath, "/r/live.jsonl",
                       "the phone and the rollout watcher both read this path")
        XCTAssertEqual(store.watchedTranscriptURL(of: tabID), URL(fileURLWithPath: "/r/live.jsonl"),
                       "the watcher must be restarted on the new rollout, not left on the dead one")
        XCTAssertEqual(store.title(of: tabID), "the real conversation",
                       "what makes the fix visible on the Mac, not only on the phone")
    }

    // MARK: - 2. Older or equal is ignored

    /// Strictly greater, never `>=`. The older case is obvious; the equal case is the one a
    /// `>=` gets wrong, and it is not hypothetical — two threads written in the same second
    /// would flap the tab between them on every tick, forever.
    func testAThreadThatIsNotStrictlyNewerIsIgnored() async {
        for (label, candidateUpdatedAt) in [("older", 500), ("exactly equal", 1_000)] {
            let tabID = UUID()
            let t = ThreadListTransport()
            t.threads["/w/a"] = [
                entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl"),
                entry(live, updatedAt: candidateUpdatedAt, path: "/r/live.jsonl", name: "not newer"),
            ]
            let store = await makeStore(
                [codexEntry(tabID, pinned: stale, directory: "/w/a")], transport: t
            )

            await store.reconcileCodexPins()

            XCTAssertEqual(store.pinnedConversationID(of: tabID), stale, "\(label)")
            XCTAssertEqual(store.title(of: tabID), "a", "\(label): the title must not move either")
        }
    }

    // MARK: - 3. Another tab's thread is never taken

    /// A thread a second tab is already pinned to is that tab's conversation. Taking it would
    /// put two tabs on one thread — the collision `conflictedSessionIDs` exists to report
    /// after the fact — and would do it by *choice*, on this tab's behalf, while leaving this
    /// tab's own conversation unreferenced by anything.
    func testAThreadAnotherLiveTabIsPinnedToIsNeverTaken() async {
        let tabID = UUID()
        let neighbour = UUID()
        let t = ThreadListTransport()
        t.threads["/w/a"] = [
            // Newest by a wide margin, and still ineligible.
            entry(other, updatedAt: 9_000, path: "/r/other.jsonl", name: "the neighbour's"),
            entry(live, updatedAt: 2_000, path: "/r/live.jsonl", name: "mine"),
            entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl"),
        ]
        let store = await makeStore(
            [
                codexEntry(tabID, pinned: stale, directory: "/w/a"),
                // A different directory, so the two-tabs-in-one-directory guard does not fire
                // and this test is about pin ownership alone.
                codexEntry(neighbour, pinned: other, directory: "/w/b", title: "b"),
            ],
            transport: t
        )

        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: tabID), live,
                       "the newest thread the neighbour does not own")
        XCTAssertEqual(store.pinnedConversationID(of: neighbour), other,
                       "and the neighbour keeps its own")
    }

    // MARK: - 4. Two tabs in one directory

    /// The load-bearing guard. Nothing in `thread/list` says which of two tabs in a directory
    /// is driving a newly appeared thread, so a re-pin here is a coin flip whose losing side
    /// throws away the pin that remembered where a conversation was.
    func testADirectoryWithTwoLiveCodexTabsIsSkippedEntirely() async {
        let first = UUID()
        let second = UUID()
        let t = ThreadListTransport()
        t.threads["/w/a"] = [entry(live, updatedAt: 9_000, path: "/r/live.jsonl", name: "whose?")]
        let store = await makeStore(
            [
                codexEntry(first, pinned: stale, directory: "/w/a"),
                codexEntry(second, pinned: other, directory: "/w/a", title: "b"),
            ],
            transport: t
        )

        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: first), stale)
        XCTAssertEqual(store.pinnedConversationID(of: second), other)
        XCTAssertTrue(t.listed.isEmpty,
                      "the group is dropped before the round trip: there is no answer that "
                      + "could be acted on, so asking is pure cost")
    }

    // MARK: - 5. A failing RPC is per group

    /// `try?` per group, not per pass. A login whose app-server has crashed says nothing about
    /// another directory's threads, and letting its error abort the pass would let one broken
    /// server silence the feature everywhere.
    func testAFailingThreadListLeavesItsGroupAloneAndTheNextGroupStillReconciles() async {
        let broken = UUID()
        let healthy = UUID()
        let t = ThreadListTransport()
        t.failing = ["/w/broken"]
        t.threads["/w/healthy"] = [
            entry(live, updatedAt: 2_000, path: "/r/live.jsonl", name: "reconciled anyway"),
            entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl"),
        ]
        let store = await makeStore(
            [
                codexEntry(broken, pinned: stale, directory: "/w/broken"),
                codexEntry(healthy, pinned: other, directory: "/w/healthy", title: "b"),
            ],
            transport: t
        )

        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: broken), stale,
                       "not knowing is not the same as knowing the pin is wrong")
        XCTAssertEqual(store.pinnedConversationID(of: healthy), live,
                       "the second group must still reconcile after the first threw")
        XCTAssertEqual(t.listed, ["/w/broken", "/w/healthy"],
                       "and the pass must have reached the second group at all")
    }

    // MARK: - 6. No rollout path

    /// A thread with no `path` has no rollout for the watcher or the phone to read, so
    /// re-pinning to it trades one dead file for no file at all — strictly worse than leaving
    /// the tab where it is.
    func testACandidateWithNoRolloutPathIsSkippedEvenWhenItIsNewest() async {
        let tabID = UUID()
        let t = ThreadListTransport()
        t.threads["/w/a"] = [
            entry(other, updatedAt: 9_000, path: nil, name: "pathless"),
            entry(live, updatedAt: 2_000, path: "/r/live.jsonl", name: "the next newest"),
            entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl"),
        ]
        let store = await makeStore(
            [codexEntry(tabID, pinned: stale, directory: "/w/a")], transport: t
        )

        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: tabID), live,
                       "the pathless newest is skipped and the next candidate is taken")
    }

    // MARK: - 7. The directory goes on the wire verbatim

    /// The regression test for the trap that makes this component look like it simply does not
    /// work: `thread/list` matches `cwd` as an exact string and answers a non-matching one with
    /// an empty array and no error at all. A `/private` prefix, a resolved symlink or a
    /// trailing slash is therefore indistinguishable from "no threads in this directory".
    func testTheSessionsOwnDirectoryIsPassedThroughByteForByte() async {
        let awkward = "/private/var/folders/Field/ogolvy-app/"
        let tabID = UUID()
        let t = ThreadListTransport()
        let store = await makeStore(
            [codexEntry(tabID, pinned: stale, directory: awkward)], transport: t
        )

        await store.reconcileCodexPins()

        XCTAssertEqual(t.listed, [awkward],
                       "no standardizing, no symlink resolution, no trailing-slash tidying")
    }

    // MARK: - Lifecycle

    /// One subscriber, appearing with the first codex tab and going with the last — not one
    /// per account, and not left ticking over a fleet that has no codex tab in it.
    func testTheReconcilerLivesExactlyAsLongAsTheCodexTabsDo() async {
        let first = UUID()
        let second = UUID()
        let t = ThreadListTransport()
        let store = await makeStore(
            [
                codexEntry(first, pinned: stale, directory: "/w/a"),
                codexEntry(second, pinned: other, directory: "/w/b", title: "b"),
            ],
            transport: t
        )

        XCTAssertTrue(store.hasCodexPinReconcilerForTesting)

        store.closeSession(first)
        XCTAssertTrue(store.hasCodexPinReconcilerForTesting,
                      "a second codex tab still justifies it — the predicate is fleet-wide, "
                      + "because the reconciler is not per account")

        store.closeSession(second)
        XCTAssertFalse(store.hasCodexPinReconcilerForTesting)
    }

    // MARK: - 8. The scheduler

    /// A pass that outlives its tick must be dropped rather than queued: the one in flight is
    /// already asking the question the next one would ask, and queueing would pile RPC round
    /// trips up behind an app-server that has gone quiet.
    func testASecondTickDuringAnInFlightPassRunsNothing() async {
        var passes = 0
        let started = expectation(description: "the first pass started")
        let finished = expectation(description: "the first pass finished")
        // Boxed rather than captured directly: the continuation is stored from inside an
        // escaping closure and read from the test body.
        final class Box { var resume: CheckedContinuation<Void, Never>? }
        let box = Box()
        var now = ContinuousClock.now
        let reconciler = CodexPinReconciler(clock: nil, now: { now }) {
            passes += 1
            started.fulfill()
            await withCheckedContinuation { box.resume = $0 }
            finished.fulfill()
        }

        // Past the window, so nothing but the re-entrancy guard can refuse the second tick.
        now = now.advanced(by: CodexPinReconciler.throttle)
        reconciler.tick()
        await fulfillment(of: [started], timeout: 2)

        now = now.advanced(by: CodexPinReconciler.throttle * 10)
        reconciler.tick()
        XCTAssertEqual(passes, 1, "a tick landing inside an in-flight pass must run nothing")

        box.resume?.resume()
        await fulfillment(of: [finished], timeout: 2)
    }

    /// The throttle, on top of the clock's own 500 ms cadence: a pass is one JSON-RPC round
    /// trip per directory, and a human typing `codex` at a shell does not need it every beat.
    ///
    /// The first tick is throttled too — `lastPass` is seeded at construction — because a tab
    /// that has only just been created or restored is pinned to the thread it just negotiated.
    /// Where an immediate pass is genuinely needed, `resumeRestoredCodex` asks for one outright.
    func testTicksInsideTheThrottleWindowFireNoPass() async {
        let passes = expectation(description: "one pass, eventually")
        var count = 0
        var now = ContinuousClock.now
        let reconciler = CodexPinReconciler(clock: nil, now: { now }) {
            count += 1
            passes.fulfill()
        }

        reconciler.tick()
        XCTAssertEqual(count, 0, "the reconciler was built this instant; the window has not opened")

        now = now.advanced(by: .milliseconds(500))
        reconciler.tick()
        now = now.advanced(by: .seconds(4))
        reconciler.tick()
        XCTAssertEqual(count, 0, "every tick inside the window is refused, however many arrive")

        now = now.advanced(by: CodexPinReconciler.throttle)
        reconciler.tick()
        await fulfillment(of: [passes], timeout: 2)
        XCTAssertEqual(count, 1)
    }
}
