// Tests/FlightDeckTests/CodexIntegrationTests.swift
import XCTest
@testable import FlightDeck

/// The one file in this suite that runs a real `codex`. Skipped by default — see
/// `setUpWithError` — so `./scripts/test-unit.sh` stays hermetic and never spawns a process;
/// opt in with `FLIGHT_DECK_CODEX_INTEGRATION=1`.
///
/// It exists because the codex adapter leans on three undocumented behaviours of an
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
/// 3. **The restore-handshake-failure heal** — `resumeRestoredCodex` re-attaches a restored
///    tab's watcher when `startCodex()`'s real handshake fails. See that test's own doc
///    comment for what "real" turned out to mean here.
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

        _ = try await rpc.request(
            "initialize", ["clientInfo": ["name": "flight-deck-test", "version": "0"]]
        )

        let started = try await rpc.request("thread/start", ["cwd": cwd.path])
        let id = try XCTUnwrap((started["thread"] as? [String: Any])?["id"] as? String)

        // Cleanup is id-scoped and runs whether the assertions below pass or throw — a
        // `do`/`catch` rather than `defer`, because deleting needs an `await` and `defer`
        // bodies cannot suspend.
        do {
            XCTAssertFalse(try threadRowExists(id), "thread/start is expected NOT to persist")

            _ = try await rpc.request(
                "thread/name/set", ["threadId": id, "name": "flight-deck integration probe"]
            )
            let committed = try await waitUntil(timeout: 5) { try self.threadRowExists(id) }
            XCTAssertTrue(committed, "thread/name/set is expected to commit")
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

        _ = try await rpc.request(
            "initialize", ["clientInfo": ["name": "flight-deck-test", "version": "0"]]
        )

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

    // MARK: - 3. The restore-handshake-failure heal

    /// `SessionStore.startCodex()` is private, and every other store in this suite reaches
    /// codex through `overrideAdapter`, which answers `preparedAdapter` before `startCodex()`
    /// is ever called. So nothing else has ever driven a real handshake failure through
    /// `resumeRestoredCodex`'s re-attach heal (`stopWatching`/`startWatching`, taken exactly
    /// when `preparedAdapter` throws).
    ///
    /// This test drives it for real — without contriving a failure, because none is needed:
    /// `CodexProcessTransport.verifyHandshake` sends `initialize` with `rpc.request(
    /// "initialize", [:])`, and `CodexRPC.request` omits the `"params"` key entirely whenever
    /// the dictionary handed to it is empty. Both installed codex builds (codex-cli 0.142.4
    /// and 0.147.0) reject that outright — `{"error":{"code":-32600,"message":"Invalid
    /// request: missing field `params`"}}`, verified directly against both binaries — so
    /// `startCodex()`'s handshake fails **every time**, against a real `codex`, with no
    /// fixture or fault injection involved. See this task's report for why that is a serious
    /// finding on its own, well beyond what this test needs from it.
    ///
    /// If `verifyHandshake` is ever fixed to send real params, this specific failure goes
    /// away and this test will need a different way to force one — see the report.
    func testARestoredCodexTabReattachesAfterARealHandshakeFailure() async throws {
        let tabID = UUID()
        let existing = UUID()
        let cwd = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }

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

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        XCTAssertTrue(store.hasCodexStackForTesting,
            "insertSession's own startWatching should have built the lazy, unstarted stack")

        await store.codexRestoreTask?.value

        XCTAssertEqual(store.codexServerRequestsForTesting, 1,
            "resumeRestoredCodex must have asked preparedAdapter for a real, started app-server")
        XCTAssertTrue(store.hasCodexStackForTesting,
            "the heal must rebuild a stack for the tab's runtime to watch, even though the " +
            "real handshake failed and startCodex() tore the first one down")
        XCTAssertEqual(store.pinnedConversationID(of: tabID), existing,
            "a broken handshake must fall back to the pinned thread rather than inventing a new one")
        XCTAssertEqual(injector.sent, ["codex resume \(existing.uuidString.lowercased())"])
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

    /// Reads codex's own state store directly — the ground truth the whole commit rule is
    /// about — rather than asking codex about itself, which would only prove the app-server's
    /// in-memory view agrees with itself.
    private func threadRowExists(_ id: String) throws -> Bool {
        let db = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, "select count(*) from threads where id='\(id)';"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "0"
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
}
