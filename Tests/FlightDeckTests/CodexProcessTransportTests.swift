import XCTest
@testable import FlightDeck

@MainActor
final class CodexProcessTransportTests: XCTestCase {
    // MARK: - LineReassembler

    func testALineArrivingInOneChunkIsEmittedWhole() {
        var r = LineReassembler()
        XCTAssertEqual(r.feed(Data("hello\n".utf8)), ["hello"])
    }

    /// The whole point of `LineReassembler`: a read can land mid-line, and half a JSON
    /// object parses as nothing, so nothing may be emitted until the newline actually shows.
    func testALineSplitAcrossTwoChunksIsHeldBackThenEmittedWhole() {
        var r = LineReassembler()
        XCTAssertEqual(r.feed(Data(#"{"id":1,"resu"#.utf8)), [], "no newline yet — nothing to emit")
        XCTAssertEqual(r.feed(Data((#"lt":{}}"# + "\n").utf8)), [#"{"id":1,"result":{}}"#])
    }

    func testOneChunkContainingMultipleLinesEmitsAllOfThem() {
        var r = LineReassembler()
        XCTAssertEqual(r.feed(Data("one\ntwo\nthree\n".utf8)), ["one", "two", "three"])
    }

    func testATrailingPartialLineIsNotEmittedUntilItsNewlineArrives() {
        var r = LineReassembler()
        XCTAssertEqual(r.feed(Data("complete\npartial".utf8)), ["complete"])
        XCTAssertEqual(r.feed(Data(" line\n".utf8)), ["partial line"])
    }

    // MARK: - AgentLaunchError

    func testTheErrorNamesTheCause() {
        XCTAssertTrue(
            AgentLaunchError.versionTooOld(found: "0.140.0", minimum: "0.142.4")
                .errorDescription?.contains("0.142.4") ?? false,
            "the alert must say what to do, not just that something failed"
        )
    }

    func testNotInstalledNamesTheBinary() {
        XCTAssertTrue(
            AgentLaunchError.notInstalled("codex").errorDescription?.contains("codex") ?? false
        )
    }

    func testPrepareFailedCarriesTheUnderlyingReason() {
        XCTAssertTrue(
            AgentLaunchError.prepareFailed("no such thread").errorDescription?.contains("no such thread")
                ?? false
        )
    }

    // MARK: - CodexVersionProbe: parsing

    func testParsesTheVersionTokenFromCodexsVersionBanner() {
        XCTAssertEqual(CodexVersionProbe.parse("codex-cli 0.142.4\n"), "0.142.4")
    }

    func testParsesOnlyTheFirstLineWhenGivenExtraOutput() {
        XCTAssertEqual(CodexVersionProbe.parse("codex-cli 0.150.0\nsome other banner\n"), "0.150.0")
    }

    func testParseReturnsNilForEmptyOutput() {
        XCTAssertNil(CodexVersionProbe.parse(""))
    }

    func testParseReturnsNilWhenTheLastTokenIsNotAVersion() {
        XCTAssertNil(CodexVersionProbe.parse("command not found: codex\n"))
    }

    // MARK: - CodexVersionProbe: comparison

    func testExactlyTheMinimumVersionCounts() {
        XCTAssertTrue(CodexVersionProbe.isAtLeast("0.142.4", minimum: "0.142.4"))
    }

    func testAPatchBelowTheMinimumFails() {
        XCTAssertFalse(CodexVersionProbe.isAtLeast("0.142.3", minimum: "0.142.4"))
    }

    func testAMinorAboveTheMinimumPasses() {
        XCTAssertTrue(CodexVersionProbe.isAtLeast("0.143.0", minimum: "0.142.4"))
    }

    func testAMajorBelowTheMinimumFailsRegardlessOfLaterComponents() {
        XCTAssertFalse(CodexVersionProbe.isAtLeast("0.99.99", minimum: "0.142.4"))
    }

    /// Missing components compare as zero: "0.142" must be treated as older than "0.142.4",
    /// not as equal or incomparable.
    func testAMissingPatchComponentComparesAsZero() {
        XCTAssertFalse(CodexVersionProbe.isAtLeast("0.142", minimum: "0.142.4"))
    }

    // MARK: - CodexVersionProbe.check

    func testCheckPassesSilentlyWhenTheInstalledVersionMeetsTheMinimum() {
        XCTAssertNoThrow(
            try CodexVersionProbe.check(executable: "codex", run: { _ in "codex-cli 0.142.4\n" })
        )
    }

    func testCheckThrowsVersionTooOldBelowTheMinimum() {
        XCTAssertThrowsError(
            try CodexVersionProbe.check(executable: "codex", run: { _ in "codex-cli 0.140.0\n" })
        ) { error in
            XCTAssertEqual(error as? AgentLaunchError, .versionTooOld(found: "0.140.0", minimum: "0.142.4"))
        }
    }

    /// A `run` that throws models `codex` genuinely not being resolvable — the failure has to
    /// come out the same door as "ran, but produced no parseable version," so the caller
    /// doesn't need to distinguish "not found" from "found but unrunnable."
    func testCheckThrowsNotInstalledWhenRunThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try CodexVersionProbe.check(executable: "codex", run: { _ in throw Boom() })
        ) { error in
            XCTAssertEqual(error as? AgentLaunchError, .notInstalled("codex"))
        }
    }

    /// `env` exits nonzero with nothing on stdout when the named binary can't be found — no
    /// separate not-found signal exists, so unparsable output has to mean the same thing.
    func testCheckThrowsNotInstalledWhenOutputIsUnparsable() {
        XCTAssertThrowsError(
            try CodexVersionProbe.check(executable: "codex", run: { _ in "" })
        ) { error in
            XCTAssertEqual(error as? AgentLaunchError, .notInstalled("codex"))
        }
    }

    // MARK: - CodexProcessTransport.verifyHandshake

    /// In-memory transport: no subprocess, no pipes, no timing beyond what the test drives
    /// explicitly. Mirrors `CodexRPCTests.StubTransport`.
    private final class StubTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        var onSend: ((String) -> Void)?
        func send(_ line: String) { onSend?(line) }
        func reply(_ json: String) { onLine?(json) }
    }

    func testVerifyHandshakeSucceedsWhenInitializeRepliesBeforeTheTimeout() async throws {
        let t = StubTransport()
        t.onSend = { _ in t.reply(#"{"id":1,"result":{"userAgent":"flight-deck"}}"#) }
        let rpc = CodexRPC(transport: t)

        try await CodexProcessTransport.verifyHandshake(rpc, timeoutSeconds: 5)
        // No throw is the assertion; nothing further to observe.
    }

    /// A wedged app-server (spawned, alive, never answering) must not hang session creation
    /// forever. The bounded wait is what `CodexRPCError.timeout` exists for.
    func testVerifyHandshakeThrowsTimeoutWhenInitializeNeverReplies() async throws {
        let t = StubTransport()   // never replies
        let rpc = CodexRPC(transport: t)

        do {
            try await CodexProcessTransport.verifyHandshake(rpc, timeoutSeconds: 0.05)
            XCTFail("a wedged app-server must surface as a timeout, not hang forever")
        } catch CodexRPCError.timeout {}

        // The race's loser must actually be retired, not merely abandoned — this is the
        // payoff of `request` being cancellation-aware: losing the race cancels the
        // `initialize` call in flight, and its `onCancel` removes it from `pending`.
        XCTAssertEqual(rpc.pendingCount, 0, "the losing initialize request must be cleaned up, not leaked")
    }

    // MARK: - Termination convergence
    //
    // `terminate()` itself is private — real EOF and a real `terminationHandler` firing can
    // only be produced by an actual OS process, which the committed suite must not spawn.
    // `simulateEOFForTesting`/`simulateProcessTerminationForTesting` are thin, named seams
    // onto the exact same private bottleneck those two real closures call in `start()`, so
    // these tests pin the convergence/de-duplication logic itself — not a re-implementation
    // of it. What they do NOT cover is whether the real `readabilityHandler`/
    // `terminationHandler` closures actually get wired to call it; that's Task 14's
    // real-process job.

    func testExplicitStopFiresOnTerminateExactlyOnce() {
        let transport = CodexProcessTransport()
        var fireCount = 0
        transport.onTerminate = { fireCount += 1 }

        transport.stop()
        transport.stop()   // idempotent — closing tabs and app quit can both reach this

        XCTAssertEqual(fireCount, 1)
    }

    func testSimulatedEOFFiresOnTerminateExactlyOnce() {
        let transport = CodexProcessTransport()
        var fireCount = 0
        transport.onTerminate = { fireCount += 1 }

        transport.simulateEOFForTesting()
        transport.simulateEOFForTesting()

        XCTAssertEqual(fireCount, 1)
    }

    func testSimulatedProcessTerminationHandlerFiresOnTerminateExactlyOnce() {
        let transport = CodexProcessTransport()
        var fireCount = 0
        transport.onTerminate = { fireCount += 1 }

        transport.simulateProcessTerminationForTesting()
        transport.simulateProcessTerminationForTesting()

        XCTAssertEqual(fireCount, 1)
    }

    /// The convergence the review asked for: however many of the three ways this can fire
    /// actually fire — in any order — the owner is told exactly once, never zero and never
    /// more than one.
    func testStopEOFAndTerminationHandlerAllConvergeOnASingleFire() {
        let transport = CodexProcessTransport()
        var fireCount = 0
        transport.onTerminate = { fireCount += 1 }

        transport.stop()
        transport.simulateEOFForTesting()
        transport.simulateProcessTerminationForTesting()

        XCTAssertEqual(fireCount, 1, "however many ways this fires, the owner must be told exactly once")
    }

    /// `deinit` is a resource-cleanup backstop (don't orphan the OS process), not a
    /// notification channel — by the time it runs there is no owner left to notify. Dropping
    /// the last reference without ever calling `stop()` must not crash and must not fire
    /// `onTerminate`.
    func testDeinitDoesNotFireOnTerminate() {
        var fireCount = 0
        var transport: CodexProcessTransport? = CodexProcessTransport()
        transport?.onTerminate = { fireCount += 1 }

        transport = nil

        XCTAssertEqual(fireCount, 0, "deinit is a backstop for the process, not a callback to a gone owner")
    }
}
