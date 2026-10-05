import FleetKit
import XCTest

/// The `flightdeck` side of delegation, driven frame by frame over `FakeTransport`: what is
/// printed, and the §5 exit statuses.
final class DelegationCLIRunnerTests: XCTestCase {
    private var out: [String] = []
    private var err: [String] = []
    private var written: [(String, Data)] = []
    private var execs: [(String, [String])] = []
    /// Set to make the next raw write fail, as stdout's reader going away does (`| head`).
    private var writeError: Error?
    private var code: Int32?
    private var scheduled: [(TimeInterval, () -> Void)] = []

    private func runner(_ args: String..., transport: FakeTransport, env: [String: String] = [:],
                        isTTY: Bool = true) -> CLIRunner {
        let invocation = (try? CLIArguments.parse(args)) ?? CLIInvocation(command: .help)
        let r = CLIRunner(invocation: invocation, transport: transport,
                          context: CLIContext(selfID: nil, cwd: "/w/a", json: false, isTTY: isTTY, environment: env),
                          out: { self.out.append($0) }, err: { self.err.append($0) },
                          finish: { self.code = $0 }, schedule: { self.scheduled.append(($0, $1)) },
                          write: {
                              if let error = self.writeError { throw error }
                              self.written.append(($0, $1))
                          }, execReal: { self.execs.append(($0, $1)) })
        r.run()
        transport.push(.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial))
        return r
    }

    private func lastCID(_ t: FakeTransport) -> Int {
        guard case .req(let cid, _) = t.sent.last else { XCTFail("\(t.sent)"); return -1 }
        return cid
    }

    /// `run` without a recipe still reads the recipe book first (a route may pick a `long`
    /// one); this answers it with `book`.
    private func answerBook(_ t: FakeTransport, _ book: WireRecipeBook = WireRecipeBook(defaultHost: nil, include: [], recipes: [], routes: [])) {
        guard case .req(let cid, .delegate(.recipeList("/w/a"))) = t.sent.last else { return XCTFail("\(t.sent)") }
        t.push(.recipes(cid: cid, book))
    }

    func testRunStreamsRawOutputAndExitsWithTheRemoteStatus() {
        let t = FakeTransport()
        _ = runner("run", "--on", "mini", "--", "make", "test", transport: t)
        answerBook(t)
        guard case .req(let cid, .delegate(.run(let run))) = t.sent.last else { return XCTFail("\(t.sent)") }
        XCTAssertEqual(run, WireDelegateRun(cwd: "/w/a", host: "mini", command: ["make", "test"]))
        t.push(.delegateStarted(cid: cid, WireDelegateStarted(runID: "r1", host: "mini")))
        t.push(.delegateOutput(cid: cid, stream: "stdout", offset: 0, data: Data("ok".utf8)))
        t.push(.delegateOutput(cid: cid, stream: "stderr", offset: 2, data: Data("no".utf8)))
        XCTAssertNil(code)
        t.push(.delegateExit(cid: cid, status: 137))
        XCTAssertEqual(code, 137, "a signal's 128+n passes straight through")
        XCTAssertEqual(written.map(\.0), ["stdout", "stderr"])
        XCTAssertEqual(written.map { String(decoding: $0.1, as: UTF8.self) }, ["ok", "no"])
        XCTAssertTrue(out.isEmpty, "an attached run prints only its own output")
    }

    func testADelegationFailureIs125WithOneLine() {
        let t = FakeTransport()
        _ = runner("run", "--on", "mini", "--", "make", transport: t)
        answerBook(t)
        t.push(.err(cid: lastCID(t), code: "host_offline", message: "mini is offline (last seen 4m ago)"))
        XCTAssertEqual(code, 125)
        XCTAssertEqual(err, ["flightdeck: mini is offline (last seen 4m ago)"])
    }

    func testAWaitTimeoutIs124() {
        let t = FakeTransport()
        _ = runner("wait", "r7", "--timeout", "30", transport: t)
        guard case .req(let cid, .delegate(.wait("r7", 30, nil, false))) = t.sent.last else { return XCTFail("\(t.sent)") }
        t.push(.err(cid: cid, code: "wait_timeout", message: "r7 is still running on mini after 30s"))
        XCTAssertEqual(code, 124)
    }

    func testAWaitExitsWithTheRunsStatus() {
        let t = FakeTransport()
        _ = runner("wait", "r7", transport: t)
        t.push(.delegateExit(cid: lastCID(t), status: 2))
        XCTAssertEqual(code, 2)
    }

    /// A `long` recipe detaches: the CLI learns that from the book and says so in `detach`, so
    /// it and the app agree that `delegateStarted` ends the stream.
    func testALongRecipeDetachesAndPrintsHowToWait() {
        let t = FakeTransport()
        _ = runner("run", "ui-tests", transport: t)
        answerBook(t, WireRecipeBook(defaultHost: "mini", include: [],
                                     recipes: [WireRecipe(name: "ui-tests", run: "xcodebuild test", long: true)], routes: []))
        guard case .req(let cid, .delegate(.run(let run))) = t.sent.last else { return XCTFail() }
        XCTAssertTrue(run.detach)
        t.push(.delegateStarted(cid: cid, WireDelegateStarted(runID: "r4", host: "mini")))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, ["r4 started on mini", "flightdeck wait r4 for its result"])
    }

    func testUpPrintsTheChosenLocalPort() {
        let t = FakeTransport()
        _ = runner("up", "stack", transport: t)
        t.push(.delegateStarted(cid: lastCID(t), WireDelegateStarted(
            runID: "r5", host: "box", ports: [WirePortBinding(local: 49152, remote: 5432)])))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out.first, "r5 started on box — localhost:49152 → box:5432")
    }

    /// Ctrl-C stops the run on the host and keeps streaming to its end; a second leaves.
    func testInterruptStopsTheRunThenASecondLeaves() {
        let t = FakeTransport()
        let r = runner("exec", "--on", "mini", "--", "sleep", "100", transport: t)
        let cid = lastCID(t)
        t.push(.delegateStarted(cid: cid, WireDelegateStarted(runID: "r2", host: "mini")))
        r.interrupt()
        guard case .req(_, .delegate(.stop("r2"))) = t.sent.last else { return XCTFail("\(t.sent)") }
        XCTAssertNil(code)
        t.push(.delegateExit(cid: cid, status: 130))
        XCTAssertEqual(code, 130)

        let t2 = FakeTransport()
        code = nil
        let r2 = runner("exec", "--on", "mini", "--", "sleep", "100", transport: t2)
        t2.push(.delegateStarted(cid: lastCID(t2), WireDelegateStarted(runID: "r3", host: "mini")))
        r2.interrupt()
        r2.interrupt()
        XCTAssertEqual(code, 130)
    }

    /// The app went away mid-run: the CLI reconnects and resumes from the first byte it has not
    /// printed, so nothing is lost or printed twice.
    func testADroppedConnectionResumesFromTheNextUnseenByte() {
        let t = FakeTransport()
        _ = runner("exec", "--on", "mini", "--", "make", transport: t)
        let cid = lastCID(t)
        t.push(.delegateStarted(cid: cid, WireDelegateStarted(runID: "r9", host: "mini")))
        t.push(.delegateOutput(cid: cid, stream: "stdout", offset: 0, data: Data("abc".utf8)))
        t.onDisconnect?(nil)
        XCTAssertNil(code)
        scheduled.forEach { $0.1() }
        XCTAssertEqual(t.connects.count, 2)
        t.push(.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial))
        guard case .req(let resumed, .delegate(.wait("r9", nil, 3, true))) = t.sent.last else { return XCTFail("\(t.sent)") }
        // An overlapping replay prints only the new bytes.
        t.push(.delegateOutput(cid: resumed, stream: "stdout", offset: 2, data: Data("cde".utf8)))
        t.push(.delegateExit(cid: resumed, status: 0))
        XCTAssertEqual(written.map { String(decoding: $0.1, as: UTF8.self) }.joined(), "abcde")
        XCTAssertEqual(code, 0)
    }

    func testDiffPrintsThePatchOrItsPath() {
        let t = FakeTransport()
        _ = runner("diff", "r1", transport: t)
        t.push(.delegatePatch(cid: lastCID(t), WireDelegatePatch(runID: "r1", patch: "diff --git\n")))
        XCTAssertEqual(written.map { String(decoding: $0.1, as: UTF8.self) }, ["diff --git\n"])
        let t2 = FakeTransport()
        _ = runner("diff", "r1", transport: t2)
        t2.push(.delegatePatch(cid: lastCID(t2), WireDelegatePatch(runID: "r1", patchPath: "/x/r1.patch")))
        XCTAssertEqual(out.last, "/x/r1.patch")
    }

    func testApplyWithConflictsExitsOne() {
        let t = FakeTransport()
        _ = runner("apply", "r1", transport: t)
        t.push(.delegateApplied(cid: lastCID(t), WireDelegateApplied(runID: "r1", conflicts: ["a.swift"])))
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.joined().contains("a.swift"))
    }

    func testRouteExecDelegatesOnAMatchAndExecsOtherwise() {
        let book = WireRecipeBook(defaultHost: "mini", include: [], recipes: [WireRecipe(name: "ui", run: "x")],
                                  routes: [WireRoute(match: "xcodebuild test *", recipe: "ui")])
        let matched = FakeTransport()
        _ = runner("route-exec", "xcodebuild", "--", "test", "-scheme", "X", transport: matched)
        answerBook(matched, book)
        guard case .req(_, .delegate(.run(let run))) = matched.sent.last else { return XCTFail("\(matched.sent)") }
        XCTAssertEqual(run.command, ["xcodebuild", "test", "-scheme", "X"])
        XCTAssertNil(run.recipe, "the app routes the argv, so it runs as written")

        let missed = FakeTransport()
        _ = runner("route-exec", "xcodebuild", "--", "build", transport: missed)
        answerBook(missed, book)
        XCTAssertEqual(execs.last?.0, "xcodebuild")
        XCTAssertEqual(execs.last?.1, ["build"])

        // No app at all: still runs, locally.
        let unreachable = FakeTransport()
        let invocation = try! CLIArguments.parse(["route-exec", "make", "--", "all"])
        CLIRunner(invocation: invocation, transport: unreachable,
                  context: CLIContext(selfID: nil, cwd: "/w/a", json: false, isTTY: true),
                  out: { _ in }, err: { _ in }, finish: { self.code = $0 }, schedule: { _, _ in },
                  execReal: { self.execs.append(($0, $1)) }).run()
        unreachable.onDisconnect?(nil)
        XCTAssertEqual(execs.last?.0, "make")

        // The bypass never connects.
        let bypass = FakeTransport()
        _ = runner("route-exec", "make", "--", "x", transport: bypass, env: ["FLIGHTDECK_NO_ROUTE": "1"])
        XCTAssertTrue(bypass.connects.isEmpty)
        XCTAssertEqual(execs.last?.1, ["x"])
    }

    /// A run that never started is a delegation failure: 125, one line, the next step.
    func testADropBeforeStartedIs125() {
        let t = FakeTransport()
        _ = runner("exec", "--on", "mini", "--", "make", transport: t)
        t.onDisconnect?(nil)
        XCTAssertEqual(code, 125)
        XCTAssertEqual(err.count, 1)
        XCTAssertTrue(err[0].hasPrefix("flightdeck: "), err[0])

        let unreachable = FakeTransport()
        code = nil
        err = []
        let invocation = try! CLIArguments.parse(["wait", "r1"])
        CLIRunner(invocation: invocation, transport: unreachable,
                  context: CLIContext(selfID: nil, cwd: "/w/a", json: false, isTTY: true),
                  out: { _ in }, err: { self.err.append($0) }, finish: { self.code = $0 }, schedule: { _, _ in }).run()
        unreachable.onDisconnect?(nil)
        XCTAssertEqual(code, 125, "cannot reach the app is a delegation failure for run, exec and wait")
        XCTAssertEqual(err.count, 1)
    }

    /// A service recipe run through `run` detaches, as `up` does: the CLI says so in `detach`.
    func testAServiceRecipeDetaches() {
        let t = FakeTransport()
        _ = runner("run", "db", transport: t)
        answerBook(t, WireRecipeBook(defaultHost: "mini", include: [],
                                     recipes: [WireRecipe(name: "db", run: "postgres", service: true)], routes: []))
        guard case .req(_, .delegate(.run(let run))) = t.sent.last else { return XCTFail() }
        XCTAssertTrue(run.detach)
    }

    /// `exec` never routes, so it never asks for the recipe book.
    func testExecDoesNotReadTheBook() {
        let t = FakeTransport()
        _ = runner("exec", "--on", "mini", "--", "xcodebuild", "build", transport: t)
        guard case .req(_, .delegate(.exec(let run))) = t.sent.last else { return XCTFail("\(t.sent)") }
        XCTAssertFalse(run.detach)
    }

    func testApplyWithNothingToApplyExitsNonZero() {
        let t = FakeTransport()
        _ = runner("apply", "r1", transport: t)
        t.push(.err(cid: lastCID(t), code: "nothing_to_apply", message: "r1 changed no files — nothing to apply"))
        XCTAssertEqual(code, 1)
    }

    /// Ctrl-C before the run has an id still stops it, once the id arrives.
    func testInterruptBeforeStartedStopsWhenTheIdArrives() {
        let t = FakeTransport()
        let r = runner("exec", "--on", "mini", "--", "sleep", "9", transport: t)
        let cid = lastCID(t)
        r.interrupt()
        XCTAssertNil(code)
        t.push(.delegateStarted(cid: cid, WireDelegateStarted(runID: "r6", host: "mini")))
        guard case .req(_, .delegate(.stop("r6"))) = t.sent.last else { return XCTFail("\(t.sent)") }
    }

    /// Ctrl-C on `wait` only stops waiting: the run is not cancelled.
    func testInterruptOnWaitDetaches() {
        let t = FakeTransport()
        let r = runner("wait", "r6", transport: t)
        r.interrupt()
        XCTAssertEqual(code, 130)
        XCTAssertFalse(t.sent.contains { if case .req(_, .delegate(.stop)) = $0 { return true }; return false })
    }

    func testAnAttachedRunNamesItsIdOnceOnStderr() {
        let t = FakeTransport()
        _ = runner("exec", "--on", "mini", "--", "make", transport: t)
        t.push(.delegateStarted(cid: lastCID(t), WireDelegateStarted(runID: "r8", host: "mini")))
        XCTAssertEqual(err.count, 1)
        XCTAssertTrue(err.first?.contains("r8") == true)
    }

    /// `flightdeck run … | head`: the reader leaving is EPIPE, not a crash. The CLI detaches
    /// with 141 and prints nothing more; nothing stops the run.
    func testABrokenPipeDetachesWith141() {
        let t = FakeTransport()
        _ = runner("exec", "--on", "mini", "--", "yes", transport: t)
        let cid = lastCID(t)
        t.push(.delegateStarted(cid: cid, WireDelegateStarted(runID: "r1", host: "mini")))
        writeError = POSIXError(.EPIPE)
        t.push(.delegateOutput(cid: cid, stream: "stdout", offset: 0, data: Data("y\n".utf8)))
        XCTAssertEqual(code, 141)
        let sentBefore = t.sent.count
        t.push(.delegateOutput(cid: cid, stream: "stdout", offset: 2, data: Data("y\n".utf8)))
        XCTAssertEqual(t.sent.count, sentBefore)
        XCTAssertFalse(t.sent.contains { if case .req(_, .delegate(.stop)) = $0 { return true }; return false })
    }

    /// The app ended the stream because this reader fell behind: the CLI picks the run back up
    /// from its next unprinted byte on the same connection, with no timeout.
    func testASlowReaderResumesFromItsOffset() {
        let t = FakeTransport()
        _ = runner("exec", "--on", "mini", "--", "make", transport: t)
        let cid = lastCID(t)
        t.push(.delegateStarted(cid: cid, WireDelegateStarted(runID: "r3", host: "mini")))
        t.push(.delegateOutput(cid: cid, stream: "stdout", offset: 0, data: Data("abcd".utf8)))
        t.push(.err(cid: cid, code: "slow_reader", message: "x"))
        XCTAssertNil(code)
        guard case .req(_, .delegate(.wait("r3", nil, 4, true))) = t.sent.last else { return XCTFail("\(t.sent)") }
    }

    /// A dropped app that never comes back ends the run's CLI with 125 and the next step,
    /// not a reconnect loop forever.
    func testReconnectsAreBounded() {
        let t = FakeTransport()
        _ = runner("exec", "--on", "mini", "--", "make", transport: t)
        t.push(.delegateStarted(cid: lastCID(t), WireDelegateStarted(runID: "r4", host: "mini")))
        for _ in 0...DelegateCommandRunner.reconnectLimit {
            t.onDisconnect?(nil)
            scheduled.forEach { $0.1() }
            scheduled = []
        }
        XCTAssertEqual(code, 125)
        XCTAssertTrue(err.last?.contains("flightdeck wait r4") == true, "\(err)")
    }

    func testJSONDetachIncludesTheNextStep() {
        let t = FakeTransport()
        let invocation = try! CLIArguments.parse(["run", "--detach", "--on", "mini", "--", "make"])
        CLIRunner(invocation: invocation, transport: t,
                  context: CLIContext(selfID: nil, cwd: "/w/a", json: true, isTTY: false),
                  out: { self.out.append($0) }, err: { _ in }, finish: { self.code = $0 }, schedule: { _, _ in }).run()
        t.push(.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial))
        t.push(.delegateStarted(cid: lastCID(t), WireDelegateStarted(runID: "r2", host: "mini")))
        XCTAssertEqual(out, [#"{"host":"mini","next":"flightdeck wait r2","ports":[],"runID":"r2"}"#])
    }

    func testSyncAcceptsARestart() {
        let t = FakeTransport()
        _ = runner("sync", "db", transport: t)
        t.push(.delegateStarted(cid: lastCID(t), WireDelegateStarted(runID: "r9", host: "mini")))
        XCTAssertEqual(code, 0)
        let plain = FakeTransport()
        code = nil
        _ = runner("sync", "db", transport: plain)
        plain.push(.ack(cid: lastCID(plain)))
        XCTAssertEqual(code, 0)
    }

    /// The real binary must get Ctrl-C and `kill` back: an ignored signal stays ignored across
    /// `exec`.
    func testRouteExecRestoresDefaultSignalsBeforeExec() {
        let saved = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, saved) }
        DelegateRouting.resetSignals()
        var action = sigaction()
        sigaction(SIGINT, nil, &action)
        XCTAssertEqual(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self), unsafeBitCast(SIG_DFL, to: Int.self))
    }

    func testRouteResolutionSkipsTheShimDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-route-\(UUID().uuidString.prefix(6))")
        let shim = root.appendingPathComponent("shim"), real = root.appendingPathComponent("bin")
        for dir in [shim, real] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tool = dir.appendingPathComponent("tool")
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let path = "\(shim.path):\(real.path)"
        XCTAssertEqual(DelegateRouting.resolve("tool", path: path, shimDir: shim.path), real.appendingPathComponent("tool").path)
        XCTAssertEqual(DelegateRouting.resolve("tool", path: real.path, shimDir: nil), real.appendingPathComponent("tool").path)
        XCTAssertNil(DelegateRouting.resolve("nope", path: path, shimDir: shim.path))
        XCTAssertEqual(DelegateRouting.recipe(for: ["make", "a/b"], in: [WireRoute(match: "make *", recipe: "m")]), "m")
    }
}
