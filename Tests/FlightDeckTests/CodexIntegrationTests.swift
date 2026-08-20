// Tests/FlightDeckTests/CodexIntegrationTests.swift
import XCTest
@testable import FlightDeck

/// The one file in this suite that runs a real `codex`. Skipped by default — see
/// `setUpWithError` — so `./scripts/test-unit.sh` stays hermetic and never spawns a process;
/// opt in with `FLIGHT_DECK_CODEX_INTEGRATION=1`.
///
/// It exists because the codex adapter leans on four undocumented behaviours of an
/// experimental, fast-moving binary, none of which the other 708 tests can see because they
/// all talk to a scripted `CodexTransport`:
///
/// 1. **The commit rule** — `thread/start` does not persist a thread; `thread/name/set` does.
///    `testThreadStartAloneDoesNotPersistButNamingCommits` below.
/// 2. **The real termination hook** — every committed test proving `CodexProcessTransport`'s
///    `onTerminate` de-dupes across EOF and `terminationHandler` does so through
///    `simulateEOFForTesting()`/`simulateProcessTerminationForTesting()`, which call the
///    private `terminate()` directly. Nothing proves the real `readabilityHandler`/
///    `terminationHandler` wiring `start()` installs is still connected to it.
///    `testKillingARealAppServerFiresTheTerminationHookAndFailsInFlightRequests` below.
/// 3. **The restore/startCodex-failure heal** — `resumeRestoredCodex` re-attaches a restored
///    tab's watcher when `startCodex()` fails for real. Forces that failure with a fake
///    `codex` shell script ahead of the real one on `PATH` for the duration of the test — a
///    `/bin/sh` stub that only `exit 1`s, needing no installed or logged-in codex at all —
///    rather than depending on any particular real binary misbehaving. See that test's own
///    doc comment for what the heal is actually responsible for and how this test isolates it.
/// 4. **The rollout vocabulary** — `task_started`/`task_complete` are still what a turn looks
///    like in the rollout file `thread/start` named, and a separate process still appends to
///    it after the creating app-server has exited. `rollout.captured.jsonl` records what
///    codex wrote on one day, and no schema exists for that format, so nothing else in the
///    suite would notice a rename.
///    `testARealResumedTurnAppendsTheTurnRecordsToTheRolloutThreadStartNamed` below.
///
/// Every thread a test here creates is deleted by that same test, by the id codex handed
/// back — never by name or recency, which could catch the user's real history. Every
/// app-server spawned here is stopped on every exit path, success or failure, via `defer`.
@MainActor
final class CodexIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FLIGHT_DECK_CODEX_INTEGRATION"] == "1",
            "set FLIGHT_DECK_CODEX_INTEGRATION=1 to run against a real codex"
        )
    }

    // MARK: - 1. The commit rule

    /// The rule the whole codex adapter is built on. If `thread/start` alone ever starts
    /// persisting, `CodexAdapter.prepare` can be simplified; if `thread/name/set` ever stops
    /// committing, every codex tab silently stops being resumable — and nothing else in the
    /// committed suite would notice either flip.
    func testThreadStartAloneDoesNotPersistButNamingCommits() async throws {
        let transport = CodexProcessTransport()
        try transport.start()
        defer { transport.stop() }
        let rpc = CodexRPC(transport: transport)

        // A dedicated temp directory, not `NSTemporaryDirectory()` itself, so the thread this
        // test creates is attributable to this run specifically.
        let cwd = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }

        // The real production handshake, not a hand-rolled `initialize` call — this is what
        // proves `CodexProcessTransport.verifyHandshake` itself, not just the shape of a
        // correct request, actually succeeds against a real `codex app-server`.
        try await CodexProcessTransport.verifyHandshake(rpc)

        let started = try await rpc.request("thread/start", ["cwd": cwd.path])
        let thread = try XCTUnwrap(started["thread"] as? [String: Any])
        let id = try XCTUnwrap(thread["id"] as? String)
        // `thread/start`'s reply already names the rollout file it will eventually write —
        // the commit rule is about whether that path becomes real, not just about the sqlite
        // row, so the negative check below must watch both.
        let rolloutPath = try XCTUnwrap(thread["path"] as? String)

        // Cleanup is id-scoped and runs whether the assertions below pass or throw — a
        // `do`/`catch` rather than `defer`, because deleting needs an `await` and `defer`
        // bodies cannot suspend.
        do {
            // "Even seconds later" is the rule, not "immediately after" — a zero-delay check
            // right after `thread/start` would also pass for a codex that persists on a
            // short async delay. `staysFalse` polls the whole window instead, with the
            // app-server alive throughout, and fails the instant either artifact appears.
            let staysUnpersisted = try await staysFalse(for: 3) {
                try self.threadRowExists(id) || FileManager.default.fileExists(atPath: rolloutPath)
            }
            XCTAssertTrue(staysUnpersisted,
                "thread/start must not persist a row or a rollout file, even seconds later")

            _ = try await rpc.request(
                "thread/name/set", ["threadId": id, "name": "flight-deck integration probe"]
            )
            let committed = try await waitUntil(timeout: 5) {
                try self.threadRowExists(id) && FileManager.default.fileExists(atPath: rolloutPath)
            }
            XCTAssertTrue(committed, "thread/name/set is expected to commit both the row and the rollout file")
        } catch {
            await deleteThreadBestEffort(id, via: rpc)
            throw error
        }
        await deleteThreadBestEffort(id, via: rpc)
    }

    // MARK: - 2. The real termination hook

    /// Kills a real `codex app-server` — not `simulateEOFForTesting()`, not
    /// `simulateProcessTerminationForTesting()` — and checks that `onTerminate` still fires
    /// exactly once and that a request already in flight fails rather than hanging.
    ///
    /// Finding the spawned process's pid without guessing: `CodexProcessTransport` shells out
    /// via `/usr/bin/env codex app-server`, and `env` execs directly into `codex` rather than
    /// forking — so the pid this test process sees as a new child *is* the app-server, and
    /// `ProcessTree().children(of: getpid())` (already exercised by `ProcessTreeTests`) scopes
    /// the search to this test process's own children, not every `codex app-server` that
    /// might be running for some other reason on this machine.
    func testKillingARealAppServerFiresTheTerminationHookAndFailsInFlightRequests() async throws {
        let transport = CodexProcessTransport()
        defer { transport.stop() }
        let rpc = CodexRPC(transport: transport)

        final class TerminationCounter { var count = 0 }
        let counter = TerminationCounter()
        transport.onTerminate = { [weak rpc] in
            counter.count += 1
            rpc?.transportClosed()
        }

        let tree = ProcessTree()
        let before = tree.children(of: getpid())
        try transport.start()

        try await CodexProcessTransport.verifyHandshake(rpc)

        let spawned = tree.children(of: getpid()).subtracting(before)
        guard spawned.count == 1, let pid = spawned.first else {
            XCTFail("expected exactly one new child of this test process after start(), found \(spawned.count)")
            return
        }

        // A real, warmed-up app-server can answer `thread/list` faster than this process can
        // observe it as "in flight" — a prior version of this test raced the reply and was
        // intermittently green for the wrong reason. `SIGSTOP` removes the race outright: a
        // stopped process cannot read its pipe, so it structurally cannot reply before the
        // `SIGKILL` below reaches it, whatever the scheduler does in between. SIGKILL still
        // terminates a stopped process immediately — it is neither blockable nor catchable —
        // so this remains a real, uncooperative kill, not a graceful shutdown.
        kill(pid, SIGSTOP)

        // Registers a real pending continuation in `CodexRPC.pending` — not a fake one — so
        // this test can watch the real `transportClosed()` path resolve it, or hang forever if
        // the hook never reaches it.
        async let inFlight = rpc.request("thread/list", ["archived": false])
        await Task.yield()
        XCTAssertGreaterThan(rpc.pendingCount, 0, "the in-flight request never reached CodexRPC.pending")

        kill(pid, SIGKILL)

        let terminated = try await waitUntil(timeout: 5) { counter.count > 0 }
        XCTAssertTrue(terminated, "onTerminate never fired after the app-server was killed for real")
        XCTAssertEqual(counter.count, 1,
            "onTerminate must fire exactly once even though a real kill can produce both EOF and terminationHandler")

        do {
            _ = try await inFlight
            XCTFail("expected the in-flight request to fail once the process died, not resolve")
        } catch {
            // Any throw is the point: `rpc?.transportClosed()` from the real hook is what
            // rejects this, rather than it hanging until XCTest's own timeout kills the run.
        }
    }

    // MARK: - 3. The restore/startCodex-failure heal

    /// `SessionStore.startCodex()` is private, and every other store in this suite reaches
    /// codex through `overrideAdapter`, which answers `preparedAdapter` before `startCodex()`
    /// is ever called. So nothing else has ever driven a real `startCodex()` failure through
    /// `resumeRestoredCodex`'s re-attach heal (`stopWatching`/`startWatching`, taken exactly
    /// when `preparedAdapter` throws).
    ///
    /// This used to force that failure for free: `CodexProcessTransport.verifyHandshake` sent
    /// `initialize` with `rpc.request("initialize", [:])`, which real codex rejected outright
    /// (`-32600 missing field 'params'`), so `startCodex()` failed every time against a real
    /// `codex` with no fault injection needed. That was a genuine bug — see this task's
    /// report — and it is now fixed, which means this test needs a real failure of its own to
    /// exercise the heal. It gets one the same way: through the real `CodexVersionProbe.check`
    /// code path, spawning a real (if substitute) process via `/usr/bin/env` — not by stubbing
    /// anything inside `SessionStore` or `CodexProcessTransport`. A fake `codex` on `PATH`
    /// that exits non-zero on `--version` makes `startCodex()` throw
    /// `AgentLaunchError.notInstalled` for exactly the reason a user with a broken PATH would
    /// see it: nothing about the heal's own logic is contrived, only which real codepath trips
    /// it.
    func testARestoredCodexTabReattachesAfterAStartCodexFailure() async throws {
        let tabID = UUID()
        let existing = UUID()
        let cwd = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }

        // A fake `codex` that fails `--version`, ahead of the real one on `PATH` for the
        // duration of this test only. `/usr/bin/env codex …` — what both `CodexVersionProbe`
        // and `CodexProcessTransport` shell out through — resolves against `PATH` exactly like
        // a shell would, so this reaches the real spawn-and-parse code without touching
        // `SessionStore` or the transport at all.
        let fakeCodexDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: fakeCodexDir) }
        let fakeCodex = fakeCodexDir.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 1\n".write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(fakeCodexDir.path):\(originalPath)", 1)
        defer { setenv("PATH", originalPath, 1) }

        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(
                id: tabID,
                title: "restored",
                workingDirectory: cwd.path,
                pinnedConversationID: existing,
                agent: .codex,
                transcriptPath: "/does/not/exist.jsonl"
            )],
            selectedSessionID: tabID,
            sessionCounter: 1
        )

        // `provider: nil` deliberately: this test needs no real terminal surface, only the
        // store's own bookkeeping around the stack and the attachment.
        let store = SessionStore(provider: nil, persistence: persistence)
        let injector = SpyInjector()
        store.injectorOverride = injector
        // Set before anything builds the codex stack, or the runtime captures the real
        // `~/.codex/session_index.jsonl` instead and this test reads the user's live state.
        let indexDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: indexDir) }
        let index = indexDir.appendingPathComponent("session_index.jsonl")
        FileManager.default.createFile(atPath: index.path, contents: Data())
        store.codexIndexURLOverride = index

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        XCTAssertTrue(store.hasCodexStackForTesting,
            "insertSession's own startWatching should have built the lazy, unstarted stack")

        await store.codexRestoreTask?.value

        XCTAssertEqual(store.codexServerRequestsForTesting, 1,
            "resumeRestoredCodex must have asked preparedAdapter for a real, started app-server")
        XCTAssertTrue(store.hasCodexStackForTesting,
            "the heal must rebuild a stack for the tab's runtime to watch, even though " +
            "startCodex() failed for real and tore the first one down")
        XCTAssertEqual(store.pinnedConversationID(of: tabID), existing,
            "a failed startCodex() must fall back to the pinned thread rather than inventing a new one")
        XCTAssertEqual(injector.sent, ["codex resume \(existing.uuidString.lowercased())"])

        // The assertions above hold whether or not the heal exists: `hasCodexStackForTesting`
        // above flips true from `resumeRestoredCodex`'s own `self.adapter(for: instance)`
        // fallback line — reached before the heal ever runs — and the pin/injector checks
        // only prove `startCodex()` failed and the tab degraded to its pin, not that anything
        // got re-attached. What the heal is actually responsible for is which *runtime
        // instance* holds this tab's attachment: a `CodexRuntime` registers each attached tab
        // with its own private, per-instance name watcher, so a rename only reaches this tab
        // if `.attach()` was called on the exact runtime object `store.runtime(for: .codex)`
        // returns now. `stopWatching`/`startWatching` in the heal is what makes that call;
        // without it, this tab's attachment is still the one `insertSession`'s original
        // `startWatching` made, against a runtime `startCodex()`'s failure already tore down
        // — an orphaned object whose watchers nothing reads. Deleting the heal block and
        // re-running this test confirms exactly that: this assertion goes red while every
        // assertion above it stays green.
        let currentRuntime = try XCTUnwrap(store.runtime(for: .codex, account: nil) as? CodexRuntime,
            "codex's runtime is always a CodexRuntime; draining its watchers below is how a "
            + "real rename reaches it, which is not part of the shared AgentRuntime protocol")
        // Prime, then append: the name watcher starts at end of file, so a line already
        // present when it attached is history rather than news.
        currentRuntime.drainForTesting()
        let line = #"{"id":"\#(existing.uuidString.lowercased())","thread_name":"post-heal-rename"}"# + "\n"
        let handle = try FileHandle(forWritingTo: index)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        currentRuntime.drainForTesting()
        let renamedTab = store.repos.flatMap(\.sessions).first { $0.id == tabID }
        XCTAssertEqual(renamedTab?.title, "post-heal-rename",
            "a rename line delivered on the current runtime's name watcher must still reach " +
            "this tab — true only if the heal re-attached it there")
    }

    // MARK: - 4. The rollout vocabulary

    /// The one test that can catch codex renaming the records this app reads.
    ///
    /// It pins two things at once, and both are load-bearing:
    ///
    /// 1. **A separate process appends to the rollout `thread/start` named.** This is the
    ///    fact the entire observation design rests on — our app-server does not have to be
    ///    the one that runs the turn.
    /// 2. **`task_started` and `task_complete` are still what a turn looks like.**
    ///    `rollout.captured.jsonl` records what codex wrote on one day, and no schema exists
    ///    for that format, so nothing else in the suite would notice a rename. The failure
    ///    mode without this test is silent: codex tabs simply stop moving.
    ///
    /// What this test does **not** prove: that a *live* app-server's rollout is externally
    /// appended to. The transport is stopped (see the `transport.stop()` call below) before
    /// `codex exec resume` runs, because codex-cli 0.148.0 refuses to resume a thread while
    /// the app-server that created it still holds a writer lock on it. So what this test
    /// actually pins is "a rollout survives its creator, and a separate process can still
    /// append to it" — not "a separate process can append to a rollout while the original
    /// app-server is still attached." See the comment at `transport.stop()` below for the
    /// writer-lock details, including a note on why this may also affect production.
    ///
    /// Everything happens under an isolated `CODEX_HOME` in a temp directory, so no thread
    /// cleanup is needed — the whole home is deleted — and the user's real codex history is
    /// neither read nor written.
    func testARealResumedTurnAppendsTheTurnRecordsToTheRolloutThreadStartNamed() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cwd = home.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Trusted in THIS home only. Without it `codex exec` refuses the directory, and the
        // TUI would raise a modal — neither of which a committed test may provoke.
        try """
        [projects."\(cwd.path)"]
        trust_level = "trusted"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let auth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: auth.path),
                          "needs a logged-in codex: ~/.codex/auth.json")
        try FileManager.default.copyItem(at: auth, to: home.appendingPathComponent("auth.json"))

        let transport = CodexProcessTransport(environment: ["CODEX_HOME": home.path])
        try transport.start()
        defer { transport.stop() }
        let rpc = CodexRPC(transport: transport)
        try await CodexProcessTransport.verifyHandshake(rpc)

        let started = try await rpc.request("thread/start", ["cwd": cwd.path])
        let thread = try XCTUnwrap(started["thread"] as? [String: Any])
        let id = try XCTUnwrap(thread["id"] as? String)
        let rollout = URL(fileURLWithPath: try XCTUnwrap(thread["path"] as? String))
        // Naming commits the thread. An unnamed one cannot be resumed at all — see
        // `testThreadStartAloneDoesNotPersistButNamingCommits` above.
        _ = try await rpc.request("thread/name/set", ["threadId": id, "name": "rollout vocabulary"])
        // Our own app-server holds an exclusive writer lock on the thread it just created.
        // codex-cli 0.148.0 refuses `thread/resume` — and the interactive `codex resume <id>`
        // TUI, which is what `CodexAdapter.launchCommand` spawns in production — while that
        // lock is held, failing with:
        //
        //     Error: thread/resume: thread/resume failed: thread <id> already has an active
        //     writer (code -32600)
        //
        // `thread/unsubscribe` was tried as a release mechanism and does NOT work: it answers
        // `{"status":"unsubscribed"}` but the lock stays held regardless. The only release
        // observed is the app-server process actually exiting — which is why this test stops
        // the transport here, rather than only in the `defer` below: it is what lets a
        // SEPARATE `codex exec resume` process pick the thread back up at all. `stop()` is
        // idempotent, so the deferred call after it is still safe.
        //
        // PRODUCTION NOTE (unresolved; not covered by this test): Flight Deck's real launch
        // path never stops the app-server between `thread/start`/`thread/name/set` and
        // spawning the interactive `codex resume <id>` TUI in a pty, so on codex-cli 0.148.0
        // that resume is very likely hitting this same "active writer" error in production.
        // This test cannot exercise the live-app-server case (see the class-level doc comment
        // above) and deliberately does not attempt to fix production behaviour here; it is
        // being tracked and surfaced separately.
        transport.stop()

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: rollout) { seen.append($0) }
        watcher.drain() // prime past the session_meta header

        let codex = Process()
        codex.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        codex.arguments = ["codex", "exec", "resume", "--skip-git-repo-check", id,
                           "Reply with exactly the word: ok"]
        codex.currentDirectoryURL = cwd
        codex.environment = ProcessInfo.processInfo.environment
            .merging(["CODEX_HOME": home.path]) { _, override in override }
        codex.standardOutput = FileHandle.nullDevice
        codex.standardError = FileHandle.nullDevice
        try codex.run()
        codex.waitUntilExit()
        XCTAssertEqual(codex.terminationStatus, 0, "codex exec resume failed")

        watcher.drain()
        XCTAssertEqual(seen, [.activity(.busy), .activity(.idle), .turnEnded],
                       "a turn run by a process our app-server does not own must still append "
                       + "task_started then task_complete to the rollout it named; if this "
                       + "fails, every codex tab has silently stopped moving")
    }

    // MARK: - Test doubles

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    /// Records what would have been typed at the restored tab's shell.
    private final class SpyInjector: TextInjecting {
        var sent: [String] = []
        var returns = 0
        func sendText(_ text: String) { sent.append(text) }
        func sendReturn() { returns += 1 }
        func sendKillLine() {}
        func sendYank() {}
        func readViewport() -> String? { nil }
    }

    // MARK: - Helpers

    /// A directory unique to this test run, so a thread created inside it is attributable —
    /// never `NSTemporaryDirectory()` itself, which every process on the machine shares.
    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("flight-deck-codex-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Thrown by `threadRowExists` instead of reading either failure as "no row found" — see
    /// that method's doc comment for why conflating them would be the wrong default.
    private enum ThreadProbeError: Error, CustomStringConvertible {
        case invalidID(String)
        case queryFailed(status: Int32, stderr: String)

        var description: String {
            switch self {
            case .invalidID(let id): return "refusing to build SQL from a non-UUID id: \(id)"
            case .queryFailed(let status, let stderr): return "sqlite3 exited \(status): \(stderr)"
            }
        }
    }

    /// Reads codex's own state store directly — the ground truth the whole commit rule is
    /// about — rather than asking codex about itself, which would only prove the app-server's
    /// in-memory view agrees with itself.
    ///
    /// A non-zero `sqlite3` exit — a missing db, a renamed `state_6.sqlite`, an absent
    /// `threads` table on some future codex — throws rather than reading as "no row found":
    /// treating "the probe looked at nothing" the same as "the probe looked and found
    /// nothing" is exactly how this file would go quiet the moment codex changes underneath
    /// it, instead of failing loudly the way a broken probe should.
    private func threadRowExists(_ id: String) throws -> Bool {
        // The one construct here by which a hostile value could reach the user's real
        // database. Unreachable in practice — codex mints UUIDs — but cheap to close.
        guard UUID(uuidString: id) != nil else { throw ThreadProbeError.invalidID(id) }

        let db = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, "select count(*) from threads where id='\(id)';"]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ThreadProbeError.queryFailed(status: p.terminationStatus, stderr: errText)
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Id-scoped, best-effort removal of a thread this test itself created — the only kind of
    /// cleanup this file performs. `thread/delete` also removes the rollout `.jsonl`, verified
    /// directly against a real app-server. Bounded the same way `verifyHandshake` is: a
    /// cleanup call that hangs must not hang the test that made it.
    private func deleteThreadBestEffort(_ id: String, via rpc: CodexRPC, timeoutSeconds: Double = 5) async {
        _ = try? await withThrowingTaskGroup(of: [String: Any].self) { group -> [String: Any] in
            group.addTask { try await rpc.request("thread/delete", ["threadId": id]) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CodexRPCError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CodexRPCError.timeout }
            return result
        }

        // Logged, not asserted: a cleanup failure must not fail the test it is cleaning up
        // after, but going unnoticed is how a committed thread ends up stuck in the user's
        // real history with nobody the wiser.
        if let stillThere = try? threadRowExists(id), stillThere {
            XCTContext.runActivity(named: "codex integration cleanup leak") { activity in
                activity.add(XCTAttachment(string:
                    "thread/delete did not remove \(id) from ~/.codex/state_5.sqlite — needs manual cleanup"))
            }
        }
    }

    /// Polls `condition` until it is true or `timeout` elapses. Every wait in this file is
    /// bounded this way — a hanging integration test is worse than a missing one, and this
    /// suite runs in front of a human waiting at a terminal.
    private func waitUntil(
        timeout: TimeInterval, interval: TimeInterval = 0.1, _ condition: () throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if try condition() { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// The opposite of `waitUntil`: polls `condition` for the whole `timeout` window and
    /// fails fast the instant it becomes true, rather than succeeding fast. A single check
    /// taken immediately after an action proves nothing about a claim like "not persisted,
    /// even seconds later" — something that persists on a short async delay would sail
    /// through a zero-delay check just as easily as something that never persists at all.
    private func staysFalse(
        for timeout: TimeInterval, interval: TimeInterval = 0.1, _ condition: () throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return false }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return true
    }
}
