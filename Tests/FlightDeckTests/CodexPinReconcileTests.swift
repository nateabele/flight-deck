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
        /// Methods whose reply is held back until `release()`. What lets a test park a REAL
        /// `createSession` inside the window a reconcile pass must refuse — suspended at the
        /// app-server, with `codexCreationsInFlight` raised and no tab in `repos` yet — with
        /// no sleep and no reach into store internals.
        var withholding: Set<String> = []
        /// Fired the moment a withheld request arrives, so the test can wait for the
        /// suspension it needs rather than guessing at it.
        var onWithheld: (() -> Void)?
        private var held: [Int] = []

        /// Answers everything `withholding` parked, in arrival order, so the suspended caller
        /// can finish and the test does not leak a task.
        func release() {
            let pending = held
            held.removeAll()
            for id in pending { onLine?(#"{"id":\#(id),"result":{}}"#) }
        }

        func forgetRecording() {
            methods.removeAll()
            listed.removeAll()
        }

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            guard !withholding.contains(method) else {
                held.append(id)
                onWithheld?()
                return
            }
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

    /// A real rollout file with a real mtime, and its path.
    ///
    /// Real files rather than a stubbed `FileManager`: what is under test is the fallback
    /// `reconcileCodexPins` uses when codex's own `thread/list` window does not carry the
    /// pinned thread, and the whole point of that fallback is that it reads the file system
    /// the app actually runs against. Written under its own subdirectory so it cannot be
    /// mistaken for anything `transcriptsRootOverride` scans.
    private func rollout(_ name: String, modified: Date) throws -> String {
        let directory = projectsRoot.appendingPathComponent("rollouts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("{}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url.path
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

    /// Strictly greater, never `>=`.
    ///
    /// **The equal case is the one doing the work here**, and it is not hypothetical — two
    /// threads stamped in the same second would flap the tab between them on every tick,
    /// forever. The older case is included because it is the obvious reading of the rule, but
    /// it cannot on its own tell `>` from `>=`: the tab's own pin stays in the candidate pool
    /// (`SessionStore.reconcileCodexPins` does not exclude it), and in a `sortDirection: desc`
    /// list a strictly older entry is always behind it, so the candidate *is* the current pin
    /// and either comparison re-pins the tab to exactly where it already is.
    ///
    /// The tie is what discriminates, and only if the equal-stamped *other* thread is the one
    /// selected — hence the ordering below.
    func testAThreadThatIsNotStrictlyNewerIsIgnored() async {
        for (label, candidateUpdatedAt) in [("older", 500), ("exactly equal", 1_000)] {
            let tabID = UUID()
            let t = ThreadListTransport()
            let mine = entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl")
            let theirs = entry(live, updatedAt: candidateUpdatedAt, path: "/r/live.jsonl",
                               name: "not newer")
            // Newest first, the way the server sorts. A tie may legitimately come back in
            // either order, and this is the order that makes the assertion mean something: the
            // selected candidate is `theirs`, so a `>=` regression moves the pin, the path and
            // the title somewhere visibly different rather than back onto the current pin.
            t.threads["/w/a"] = candidateUpdatedAt >= 1_000 ? [theirs, mine] : [mine, theirs]
            let store = await makeStore(
                [codexEntry(tabID, pinned: stale, directory: "/w/a")], transport: t
            )

            await store.reconcileCodexPins()

            XCTAssertEqual(store.pinnedConversationID(of: tabID), stale, "\(label)")
            let session = store.repos.flatMap(\.sessions).first { $0.id == tabID }
            XCTAssertEqual(session?.transcriptPath, "/r/stale.jsonl",
                           "\(label): the rollout the watcher and the phone read must not move")
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

    // MARK: - 4b. Closing one of the two tabs must not hand its thread to the other

    /// The regression test for the way the two-tab guard above was walked around.
    ///
    /// `taken` only ever knew the threads *currently* pinned by a live tab, so the guard held
    /// only for as long as both tabs did. Close one and its thread became takeable: the very
    /// next pass re-pinned the survivor onto a conversation its terminal was not having, moved
    /// the rollout watcher to that thread's file and renamed the tab. The state was stable —
    /// the adopted thread is then both the pin and the newest entry — and became unrecoverable
    /// at the next launch, where `resumeRestoredCodex` types `codex resume <it>` into the tab
    /// and orphans the real conversation with nothing left referencing it.
    ///
    /// `codexThreadsEverPinned` is what closes it: the closed tab's thread is remembered for
    /// the life of the process and stays untakeable.
    func testAClosedTabsThreadIsNeverHandedToTheTabThatOutlivedIt() async {
        let survivor = UUID()
        let closed = UUID()
        let t = ThreadListTransport()
        t.threads["/w/a"] = [
            // The closed tab's thread, and the newest in the directory by a wide margin —
            // which is exactly the shape a user who has been working in the tab they just
            // closed leaves behind.
            entry(other, updatedAt: 9_000, path: "/r/other.jsonl", name: "the closed tab's"),
            entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl"),
        ]
        let store = await makeStore(
            [
                codexEntry(survivor, pinned: stale, directory: "/w/a"),
                codexEntry(closed, pinned: other, directory: "/w/a", title: "b"),
            ],
            transport: t
        )

        // While both are live the group is skipped, as test 4 asserts directly.
        await store.reconcileCodexPins()
        store.closeSession(closed)
        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: survivor), stale,
                       "the survivor is still driving its own conversation; nothing about "
                       + "closing the other tab is evidence that it moved")
        let session = store.repos.flatMap(\.sessions).first { $0.id == survivor }
        XCTAssertEqual(session?.transcriptPath, "/r/stale.jsonl",
                       "the watcher and the phone must not be moved onto the closed tab's rollout")
        XCTAssertEqual(store.title(of: survivor), "a",
                       "and the tab must not be renamed to the closed tab's conversation")
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

    // MARK: - 8. A pinned thread that fell out of the window

    /// `thread/list` is capped at ten entries, so a long-lived project directory eventually
    /// pushes an idle tab's own thread off the end of it. Scoring an absent pinned thread as 0
    /// made the strictly-greater guard inert there — every candidate beats 0 — and quietly
    /// degraded the whole feature to "adopt the newest unclaimed thread". The local answer is
    /// always available instead: when its rollout was last written.
    func testAPinnedThreadOutsideTheWindowIsScoredFromItsRolloutsMtime() async throws {
        let path = try rollout("recent.jsonl", modified: Date().addingTimeInterval(-60))
        let tabID = UUID()
        let t = ThreadListTransport()
        let store = await makeStore(
            [codexEntry(tabID, pinned: stale, directory: "/w/a", path: path)], transport: t
        )
        // Installed AFTER the restore, which runs a pass of its own: the pass under test has
        // to be the one this test drives, not one that already happened.
        //
        // The pinned thread is NOT in the answer, exactly as codex reports a directory whose
        // ten newest threads are all somebody else's. The candidate's stamp is a real unix
        // second from 2023, so it is genuinely older than the rollout above.
        t.threads["/w/a"] = [entry(live, updatedAt: 1_700_000_000, path: "/r/live.jsonl", name: "older")]

        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: tabID), stale,
                       "the pinned thread's own rollout was written a minute ago; a candidate "
                       + "from 2023 is not evidence the tab moved")
        let session = store.repos.flatMap(\.sessions).first { $0.id == tabID }
        XCTAssertEqual(session?.transcriptPath, path)
    }

    /// The other half: the fallback is a real comparison, not a way of always refusing. A
    /// pinned thread whose rollout has not been written since 2001 loses to a candidate from
    /// 2023 — which is the reported bug's own shape, a stub rollout three days stale against
    /// the thread the user is actually typing into.
    func testAPinnedThreadOutsideTheWindowWithAStaleRolloutIsOvertaken() async throws {
        let path = try rollout("stale.jsonl", modified: Date(timeIntervalSince1970: 1_000_000_000))
        let tabID = UUID()
        let t = ThreadListTransport()
        let store = await makeStore(
            [codexEntry(tabID, pinned: stale, directory: "/w/a", path: path)], transport: t
        )
        // After the restore, for the same reason as the test above.
        t.threads["/w/a"] = [
            entry(live, updatedAt: 1_700_000_000, path: "/r/live.jsonl", name: "the real conversation")
        ]

        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: tabID), live,
                       "failing closed on an absent pinned thread would un-fix the bug this "
                       + "whole branch exists for")
    }

    // MARK: - 9. A creation in flight

    /// The pass reads `repos` before its round trip, and `createSession` does not put its tab
    /// in `repos` until long after `thread/name/set` has committed — and named — the thread it
    /// is claiming. A tick landing in that window sees a one-tab directory, cannot see the new
    /// thread in the rebuilt `taken`, and re-pins the existing tab onto the thread the new tab
    /// is about to be born on: two tabs, one thread, produced by the guard whose whole job is
    /// to refuse that.
    ///
    /// Driven through a real suspended `createSession` rather than by reaching into
    /// `codexCreationsInFlight`, so what is asserted is the window as it actually occurs.
    func testAPassRefusesADirectoryWhileACodexCreationIsInFlight() async {
        let tabID = UUID()
        let t = ThreadListTransport()
        let store = await makeStore(
            [codexEntry(tabID, pinned: stale, directory: "/w/a")], transport: t
        )
        // After the restore, which runs a pass of its own: with this list in place beforehand
        // the tab would already have been re-pinned before the creation even started, and the
        // assertion below would hold for a reason that has nothing to do with the guard.
        t.threads["/w/a"] = [
            entry(live, updatedAt: 9_000, path: "/r/live.jsonl", name: "the new tab's"),
            entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl"),
        ]

        let suspended = expectation(description: "the creation reached the app-server")
        t.onWithheld = { suspended.fulfill() }
        t.withholding = ["thread/start"]
        let creating = Task { await store.createSession(agent: .codex, in: "/w/a") }
        await fulfillment(of: [suspended], timeout: 5)
        // Only the pass driven below may be read: the creation itself is a legitimate caller.
        t.forgetRecording()

        await store.reconcileCodexPins()

        XCTAssertTrue(t.listed.isEmpty,
                      "the group is dropped before the round trip: no answer taken while a "
                      + "creation is uncommitted can be acted on")
        XCTAssertEqual(store.pinnedConversationID(of: tabID), stale,
                       "the existing tab must not be moved onto a thread the tab being "
                       + "created is about to claim")

        // Let the creation fail out on its own terms (an empty `thread/start` result), so
        // nothing is left suspended past the end of the test.
        t.release()
        _ = await creating.value
    }

    // MARK: - 10. An empty candidate name

    /// A thread codex reports with `"name": ""` must not become the tab's name.
    ///
    /// Two independent guards hold this — `!name.isEmpty` at the call site, and
    /// `AgentTitle.sanitized`'s empty-after-trimming rule inside `applyExternalTitle` — so
    /// this pins the behaviour rather than any one of them. The re-pin itself still has to
    /// happen: an unnamed thread is still the conversation the tab is driving.
    func testACandidateWithAnEmptyNameLeavesTheTabsTitleAlone() async {
        let tabID = UUID()
        let t = ThreadListTransport()
        t.threads["/w/a"] = [
            entry(live, updatedAt: 2_000, path: "/r/live.jsonl", name: ""),
            entry(stale, updatedAt: 1_000, path: "/r/stale.jsonl"),
        ]
        let store = await makeStore(
            [codexEntry(tabID, pinned: stale, directory: "/w/a")], transport: t
        )

        await store.reconcileCodexPins()

        XCTAssertEqual(store.pinnedConversationID(of: tabID), live,
                       "a thread with no name is still the thread the tab is driving")
        XCTAssertEqual(store.title(of: tabID), "a",
                       "and the tab keeps the name it had rather than being renamed to nothing")
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
        // `tick()` enqueues its pass rather than running it inline, so without this the
        // assertion would hold whether or not the guard exists — it would simply be reading
        // the count before any second pass could have started. The yield gives an unguarded
        // pass its chance to run, so the assertion itself is what catches a regression.
        await Task.yield()
        XCTAssertEqual(passes, 1, "a tick landing inside an in-flight pass must run nothing")

        box.resume?.resume()
        await fulfillment(of: [finished], timeout: 2)
    }

    /// The throttle, on top of the clock's own 500 ms cadence: a pass is one JSON-RPC round
    /// trip per directory, and a human typing `codex` at a shell does not need it every beat.
    ///
    /// The first tick is throttled too — `lastPass` is seeded at construction — because a tab
    /// that has only just been created is pinned to the thread it just negotiated. A *restored*
    /// tab is not: its pin came from a previous run. So `resumeRestoredCodex` asks for a pass
    /// outright, and takes it before it types `codex resume <id>` rather than after.
    func testTicksInsideTheThrottleWindowFireNoPass() async {
        let passes = expectation(description: "one pass, eventually")
        var count = 0
        var now = ContinuousClock.now
        let reconciler = CodexPinReconciler(clock: nil, now: { now }) {
            count += 1
            passes.fulfill()
        }

        reconciler.tick()
        // Yielded before each count is read, because `tick()` enqueues its pass rather than
        // running it inline: without this the assertions would pass even with no throttle at
        // all, merely by reading the count first.
        await Task.yield()
        XCTAssertEqual(count, 0, "the reconciler was built this instant; the window has not opened")

        now = now.advanced(by: .milliseconds(500))
        reconciler.tick()
        now = now.advanced(by: .seconds(4))
        reconciler.tick()
        await Task.yield()
        XCTAssertEqual(count, 0, "every tick inside the window is refused, however many arrive")

        // Lands on exactly one window from `lastPass` (0.5 s + 4 s + 0.5 s), not past it. The
        // boundary is the only advance that tells `>= throttle` from `> throttle`, and an
        // overshoot — this used to clear the window by 4.5 s — lets that mutation live.
        now = now.advanced(by: .milliseconds(500))
        reconciler.tick()
        await fulfillment(of: [passes], timeout: 2)
        XCTAssertEqual(count, 1)
    }
}
