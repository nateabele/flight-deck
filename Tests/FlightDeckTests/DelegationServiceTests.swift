import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

// MARK: - Fakes

/// An in-memory channel: what the service writes is captured, what the test queues is read.
final class FakeByteChannel: ByteChannel, @unchecked Sendable {
    let id: ChannelID
    var written = Data()
    var toRead: [Data]
    var finished = false
    var cancelled = false
    init(id: ChannelID, toRead: [Data] = []) { self.id = id; self.toRead = toRead }
    func write(_ data: Data) async throws { written.append(data) }
    func read() async throws -> Data? { toRead.isEmpty ? nil : toRead.removeFirst() }
    func finish() async { finished = true }
    func cancel() { cancelled = true }
}

/// A host. Events are buffered per run and replayed to every subscriber, honouring `from`,
/// which is the buffering contract `HostLinking.events` asks of C8's adapter.
@MainActor
final class FakeHostLink: HostLinking {
    let name: String
    var requests: [DelegationRequest] = []
    var nextRun = 0
    /// Bytes the next pulled channel (`run.result`/`run.artifacts`) will carry.
    var resultBytes: Data?
    var resultCommit: String?
    var nextChannel: ChannelID = 1
    var channels: [FakeByteChannel] = []
    private var events: [String: [RunEvent]] = [:]
    private var continuations: [String: [(Int64, AsyncThrowingStream<RunEvent, Error>.Continuation)]] = [:]

    init(name: String) { self.name = name }

    func request(_ request: DelegationRequest) async throws -> DelegationReply {
        requests.append(request)
        switch request {
        case .syncTips: return .syncTips(tips: [])
        case .syncPush: return .syncPush
        case .runStart:
            nextRun += 1
            return .runStart(runID: "h\(nextRun)")
        case .runCancel: return .runCancel
        case .runResult: return .runResult(commit: resultCommit)
        case .runArtifacts: return .runArtifacts(found: false)
        case .serviceDown(let id):
            emit(id, .exited(.signal(15)))
            return .serviceDown
        case .serviceSync: return .serviceSync
        default: throw HostLinkError.remote(code: "unsupported", message: "fake")
        }
    }

    func openChannel() async throws -> any ByteChannel {
        let channel = FakeByteChannel(id: nextChannel, toRead: resultBytes.map { [$0] } ?? [])
        nextChannel += 2
        channels.append(channel)
        return channel
    }

    nonisolated func events(runID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                for event in self.events[runID, default: []] { Self.deliver(event, from: offset, to: continuation) }
                if self.events[runID]?.contains(where: Self.isEnd) == true { return continuation.finish() }
                self.continuations[runID, default: []].append((offset, continuation))
            }
        }
    }

    func emit(_ runID: String, _ event: RunEvent) {
        events[runID, default: []].append(event)
        for (offset, continuation) in continuations[runID, default: []] {
            Self.deliver(event, from: offset, to: continuation)
            if Self.isEnd(event) { continuation.finish() }
        }
        if Self.isEnd(event) { continuations[runID] = nil }
    }

    private static func isEnd(_ event: RunEvent) -> Bool {
        switch event {
        case .exited, .serviceDied: return true
        default: return false
        }
    }

    private static func deliver(_ event: RunEvent, from offset: Int64,
                                to continuation: AsyncThrowingStream<RunEvent, Error>.Continuation) {
        if case .output(_, let at, let data) = event, at + Int64(data.count) <= offset { return }
        continuation.yield(event)
    }
}

@MainActor
final class FakeHosts: DelegationHostDirectory {
    var links: [String: FakeHostLink] = [:]
    var hostNames: [String] { links.keys.sorted() }
    func link(named name: String) throws -> any HostLinking {
        guard let link = links[name] else {
            throw DelegationFailure(code: "host_offline", message: "\(name) is offline (last seen 4m ago)")
        }
        return link
    }
}

final class FakeReservation: _PendingPortReservation {
    var ports: [WirePortBinding]
    var released = 0
    var forwarded: String?
    init(ports: [WirePortBinding] = []) { self.ports = ports }
    func forward(service runID: String, link: any HostLinking) { forwarded = runID }
    func release() { released += 1 }
}

final class FakePreflight: Preflighting {
    var failure: DelegationFailure?
    var plans: [DelegationPlan] = []
    var reservations: [FakeReservation] = []
    var ports: [WirePortBinding] = []
    func preflight(_ plan: DelegationPlan, link: any HostLinking) async throws -> any _PendingPortReservation {
        plans.append(plan)
        if let failure { throw failure }
        let reservation = FakeReservation(ports: ports)
        reservations.append(reservation)
        return reservation
    }
}

final class FakeSync: SnapshotMaking, BundleMaking, @unchecked Sendable {
    var snapshots = 0
    func snapshot(worktree: URL, host: String, include: [String]) async throws -> SnapshotRef {
        snapshots += 1
        return SnapshotRef(repoRoot: "root", wtKey: "wt", worktreeName: worktree.lastPathComponent,
                           commit: "c\(snapshots)", tree: "t\(snapshots)")
    }
    func bundle(worktree: URL, snapshot: SnapshotRef, haves: [String]) async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fd-bundle-\(UUID().uuidString)")
        try Data("bundle".utf8).write(to: file)
        return file
    }
}

final class FakeResults: ResultApplying {
    /// What `apply` answers when conflicts are not allowed (auto) and when they are.
    var autoOutcome: ApplyOutcome = .clean
    var applied: [(commit: String, allowConflicts: Bool)] = []
    var patchText = "diff --git a/x b/x\n"
    func patch(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL) throws -> String { patchText }
    func apply(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL, allowConflicts: Bool) throws -> ApplyOutcome {
        applied.append((commit, allowConflicts))
        return allowConflicts ? .clean : autoOutcome
    }
    func extractArtifacts(tar: URL, into worktree: URL) throws {}
}

final class FakeConfig: DelegateConfigLoading {
    var config: DelegateConfig?
    var added: [(String, Recipe)] = []
    func load(worktree: URL) throws -> DelegateConfig? { config }
    func add(_ recipe: Recipe, named name: String, worktree: URL) throws { added.append((name, recipe)) }
    func problems(in config: DelegateConfig, hosts: [String]) -> [String] {
        config.recipes.compactMap { name, r in r.host.flatMap { hosts.contains($0) ? nil : "\(name): unknown host \($0)" } }
    }
    func recipe(routing argv: [String], in config: DelegateConfig) -> String? {
        DelegationService.fnmatchRoute(argv, config.routes)
    }
}

struct FakeWorktrees: WorktreeLocating {
    var root = URL(fileURLWithPath: "/w/proj")
    func locate(cwd: URL) throws -> (worktree: URL, subdir: String) { (root, "") }
    func ignored(_ paths: [String], in worktree: URL) -> Set<String> { [] }
}

// MARK: - Tests

@MainActor
final class DelegationServiceTests: XCTestCase {
    private var hosts: FakeHosts!
    private var mini: FakeHostLink!
    private var preflight: FakePreflight!
    private var sync: FakeSync!
    private var results: FakeResults!
    private var config: FakeConfig!
    private var service: DelegationService!
    private var waitTimeouts: [TimeInterval] = []
    private let tab = UUID()
    private let otherTab = UUID()

    override func setUp() async throws {
        hosts = FakeHosts()
        mini = FakeHostLink(name: "mini")
        hosts.links["mini"] = mini
        preflight = FakePreflight()
        sync = FakeSync()
        results = FakeResults()
        config = FakeConfig()
        makeService(worktrees: FakeWorktrees())
    }

    private func makeService(worktrees: any WorktreeLocating) {
        service = DelegationService(registry: RunRegistry(file: nil), dependencies: .init(
            hosts: hosts, preflight: preflight, snapshots: sync, bundles: sync, results: results,
            config: config, worktrees: worktrees, sessionTitle: { _ in "alpha" },
            // Records the bound; a short one elapses at once, a long one (the 9-minute default)
            // never does within a test, so a wait that should end on its own still can.
            sleep: { [weak self] seconds in
                self?.waitTimeouts.append(seconds)
                if seconds >= 60 { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("fd-deleg-\(UUID().uuidString)")))
    }

    /// Sends one request and collects every frame it draws.
    private final class Frames { var all: [ServerFrame] = [] }
    private func send(_ request: DelegateRequest, as caller: ControlCaller? = nil) -> Frames {
        let frames = Frames()
        service.handle(request, caller: caller ?? .session(tab), cid: 1) { frames.all.append($0) }
        return frames
    }

    private func until(_ what: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private var terminal: (ServerFrame) -> Bool {
        { frame in
            switch frame {
            case .delegateExit, .err, .ack, .delegateRuns, .delegatePatch, .delegateApplied, .recipes, .recipeCheck,
                 .hostDisk:
                return true
            default: return false
            }
        }
    }

    private func started(_ frames: Frames) async throws -> String {
        try await until("delegateStarted") { frames.all.contains { if case .delegateStarted = $0 { return true }; return false } }
        for frame in frames.all { if case .delegateStarted(_, let s) = frame { return s.runID } }
        return ""
    }

    private func hostRunID() -> String { "h\(mini.nextRun)" }

    func testRunStreamsAndExitsWithRemoteCode() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make", "test"])))
        let id = try await started(frames)
        mini.emit(hostRunID(), .started(runID: hostRunID()))
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 0, data: Data("ok\n".utf8)))
        mini.emit(hostRunID(), .output(stream: .stderr, offset: 3, data: Data("warn\n".utf8)))
        mini.emit(hostRunID(), .exited(.code(3)))
        try await until("exit") { frames.all.contains(where: terminal) }

        XCTAssertEqual(frames.all.last, .delegateExit(cid: 1, status: 3))
        XCTAssertTrue(frames.all.contains(.delegateOutput(cid: 1, stream: "stdout", offset: 0, data: Data("ok\n".utf8))))
        XCTAssertTrue(frames.all.contains(.delegateOutput(cid: 1, stream: "stderr", offset: 3, data: Data("warn\n".utf8))))
        // Synced before it started: tips, push, then start, in that order.
        XCTAssertEqual(mini.requests.map(Self.op).prefix(3), ["sync.tips", "sync.push", "run.start"])
        guard case .runStart(_, let spec, let owner, true) = mini.requests[2] else { return XCTFail("\(mini.requests)") }
        XCTAssertEqual(spec.command, "make test")
        XCTAssertEqual(owner, "alpha", "the tab's display title, which the host prints to another tab's agent")
        XCTAssertEqual(service.registry.run(id)?.status, 3)
        XCTAssertEqual(service.registry.run(id)?.state, .exited)
    }

    func testSignalExitIs128PlusN() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["sleep 100"])))
        _ = try await started(frames)
        mini.emit(hostRunID(), .exited(.signal(9)))
        try await until { frames.all.contains(where: terminal) }
        XCTAssertEqual(frames.all.last, .delegateExit(cid: 1, status: 137))
    }

    func testDelegationFailureIs125WithOneLine() async throws {
        let line = "mini: localhost:5432 is held by postgres (pid 812) — try --port 15433:5432 or --port auto:5432"
        preflight.failure = DelegationFailure(code: "local_port_held", message: line)
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        try await until { frames.all.contains(where: terminal) }
        guard case .err(1, "local_port_held", let message?) = frames.all.last else { return XCTFail("\(frames.all)") }
        XCTAssertEqual(message, line, "the preflight's line is final: passed through, never re-prefixed")
        XCTAssertFalse(message.contains("\n"), "one line")
        XCTAssertEqual(frames.all.count, 1)
        XCTAssertTrue(mini.requests.isEmpty, "a failed preflight touches nothing remote")
        XCTAssertEqual(sync.snapshots, 0, "and syncs nothing")

        // An offline host is the directory's §5 line, verbatim.
        let offline = send(.run(WireDelegateRun(cwd: "/w/proj", host: "box", command: ["make"])))
        try await until { offline.all.contains(where: terminal) }
        XCTAssertEqual(offline.all.last, .err(cid: 1, code: "host_offline", message: "box is offline (last seen 4m ago)"))

        // A host error code maps to its §5 line, naming the host and the next step.
        XCTAssertEqual(DelegationService.hostLine(code: "screen_locked", message: "x", host: "mini"),
                       "mini's screen is locked — unlock it, then rerun")
        XCTAssertEqual(DelegationService.hostLine(code: "tree_mismatch", message: "x", host: "mini"),
                       "mini: sync rejected: tree hash mismatch — rerun; if it repeats, flightdeck host prune mini")
    }

    func testLongRecipeDetaches() async throws {
        config.config = DelegateConfig(recipes: ["ui-tests": Recipe(host: "mini", run: "xcodebuild test", long: true)])
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", recipe: "ui-tests")))
        let id = try await started(frames)
        // `delegateStarted` is the terminal frame of a detached stream: nothing follows it.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(frames.all, [.delegateStarted(cid: 1, WireDelegateStarted(runID: id, host: "mini"))])
        // It is still watched: its end lands in the registry for a later `wait`.
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { self.service.registry.run(id)?.state == .exited }
        let waited = send(.wait(run: id, timeout: nil, from: nil))
        try await until { waited.all.contains(where: terminal) }
        XCTAssertEqual(waited.all.last, .delegateExit(cid: 1, status: 0))
    }

    func testWaitTimeoutIs124RunContinues() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        let waited = send(.wait(run: id, timeout: 5, from: nil))
        try await until { waited.all.contains(where: terminal) }
        guard case .err(1, "wait_timeout", let message?) = waited.all.last else { return XCTFail("\(waited.all)") }
        XCTAssertTrue(message.contains("flightdeck wait \(id)"), message)
        XCTAssertEqual(waitTimeouts, [5])
        XCTAssertEqual(service.registry.run(id)?.state, .running, "only the wait gave up")
        XCTAssertFalse(mini.requests.contains { if case .runCancel = $0 { return true }; return false })

        // The default bound is 9 minutes.
        _ = send(.wait(run: id, timeout: nil, from: nil))
        try await until { self.waitTimeouts.count == 2 }
        XCTAssertEqual(waitTimeouts.last, 540)
    }

    func testWaitResumesFromAnOffsetWithoutRepeating() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 0, data: Data("abc".utf8)))
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 3, data: Data("def".utf8)))
        let waited = send(.wait(run: id, timeout: nil, from: 3))
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { waited.all.contains(where: terminal) }
        XCTAssertEqual(waited.all, [.delegateOutput(cid: 1, stream: "stdout", offset: 3, data: Data("def".utf8)),
                                    .delegateExit(cid: 1, status: 0)])
    }

    func testTabCloseDownsServices() async throws {
        preflight.ports = [WirePortBinding(local: 15432, remote: 5432)]
        let up = send(.up(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["postgres"], ports: ["15432:5432"])))
        let id = try await started(up)
        XCTAssertEqual(up.all.last, .delegateStarted(cid: 1, WireDelegateStarted(
            runID: id, host: "mini", ports: [WirePortBinding(local: 15432, remote: 5432)])))
        XCTAssertEqual(preflight.reservations.first?.forwarded, hostRunID())
        let other = send(.up(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["redis"])), as: .session(otherTab))
        let otherID = try await started(other)

        service.sessionClosed(tab)
        try await until { self.service.registry.run(id)?.state == .exited }
        XCTAssertTrue(mini.requests.contains(.serviceDown(service: "h1")))
        XCTAssertFalse(mini.requests.contains(.serviceDown(service: "h2")), "another tab's service keeps running")
        XCTAssertEqual(preflight.reservations.first?.released ?? 0 > 0, true, "its forwards are released")
        XCTAssertEqual(service.registry.run(otherID)?.state, .running)
    }

    /// Review Focus 5.
    func testMissingIgnoredFileHint() async throws {
        let repo = try Self.tempRepo(ignored: [".env"], files: [".env", "tracked.txt", "build/out.log"],
                                     gitignore: ".env\nbuild/\n")
        makeService(worktrees: GitWorktreeLocator())
        // Names an ignored local file that wasn't sent: the hint.
        let failed = send(.run(WireDelegateRun(cwd: repo.path, host: "mini", command: ["make"])))
        _ = try await started(failed)
        mini.emit(hostRunID(), .output(stream: .stderr, offset: 0,
                                       data: Data("Error: ENOENT: no such file or directory, open '/Users/h/ws/checkouts/wt-0/\(repo.lastPathComponent)/.env'\n".utf8)))
        mini.emit(hostRunID(), .exited(.code(1)))
        try await until { failed.all.contains(where: terminal) }
        XCTAssertEqual(failed.all.last, .err(cid: 1, code: "missing_include",
                                             message: "mini: .env is ignored locally and wasn't sent — rerun with --include .env or add it to delegate.toml"))

        // No hint for: a tracked file, a path that doesn't exist here, one that was sent, or a run that succeeded.
        for (stderr, include, code) in [("tracked.txt: missing", [String](), Int32(1)), ("nope.env: missing", [], 1),
                                        (".env: missing", [".env"], 1), (".env: missing", [], 0)] {
            let frames = send(.run(WireDelegateRun(cwd: repo.path, host: "mini", command: ["make"], include: include)))
            _ = try await started(frames)
            mini.emit(hostRunID(), .output(stream: .stderr, offset: 0, data: Data(stderr.utf8)))
            mini.emit(hostRunID(), .exited(.code(code)))
            try await until { frames.all.contains(where: terminal) }
            XCTAssertEqual(frames.all.last, .delegateExit(cid: 1, status: code), "\(stderr) \(include)")
        }
    }

    func testAutoApplyFallsBackToReviewOnConflict() async throws {
        config.config = DelegateConfig(recipes: ["gen": Recipe(host: "mini", run: "make gen", apply: .auto)])
        mini.resultCommit = "res1"
        mini.resultBytes = Data("bundle".utf8)
        results.autoOutcome = .conflicts(["Sources/A.swift"])
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", recipe: "gen")))
        let id = try await started(frames)
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { frames.all.contains(where: terminal) }

        XCTAssertEqual(results.applied.map(\.allowConflicts), [false], "auto never writes conflict markers")
        XCTAssertTrue(frames.all.contains {
            if case .delegateNotice(_, let m) = $0 { return m.contains("conflict") && m.contains("flightdeck diff \(id)") }
            return false
        }, "\(frames.all)")
        XCTAssertEqual(frames.all.last, .delegateExit(cid: 1, status: 0))
        XCTAssertEqual(service.registry.run(id)?.resultCommit, "res1", "kept for review")

        let diff = send(.diff(run: id))
        try await until { diff.all.contains(where: terminal) }
        XCTAssertEqual(diff.all.last, .delegatePatch(cid: 1, WireDelegatePatch(runID: id, patch: results.patchText)))
        let applied = send(.apply(run: id))
        try await until { applied.all.contains(where: terminal) }
        XCTAssertEqual(applied.all.last, .delegateApplied(cid: 1, WireDelegateApplied(runID: id, conflicts: [])))
        XCTAssertNil(service.registry.run(id)?.resultCommit)
    }

    func testAutoApplyAppliesWhenClean() async throws {
        config.config = DelegateConfig(recipes: ["gen": Recipe(host: "mini", run: "make gen", apply: .auto)])
        mini.resultCommit = "res1"
        mini.resultBytes = Data("bundle".utf8)
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", recipe: "gen")))
        let id = try await started(frames)
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { frames.all.contains(where: terminal) }
        XCTAssertEqual(results.applied.map(\.allowConflicts), [false])
        XCTAssertNil(service.registry.run(id)?.resultCommit)
    }

    func testAPatchOverOneMebibyteComesBackAsAFile() async throws {
        results.patchText = String(repeating: "x", count: 1024 * 1024 + 1)
        mini.resultCommit = "res1"
        mini.resultBytes = Data("bundle".utf8)
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        let id = try await started(frames)
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { frames.all.contains(where: terminal) }
        let diff = send(.diff(run: id))
        try await until { diff.all.contains(where: terminal) }
        guard case .delegatePatch(_, let patch) = diff.all.last, let path = patch.patchPath else { return XCTFail("\(diff.all.count)") }
        XCTAssertNil(patch.patch)
        XCTAssertEqual(try String(contentsOfFile: path).count, results.patchText.count)
    }

    func testOnlyOwningSessionSeesItsRuns() async throws {
        let mine = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let myRun = try await started(mine)
        let theirs = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)),
                          as: .session(otherTab))
        let theirRun = try await started(theirs)

        let ps = send(.ps)
        try await until { ps.all.contains(where: terminal) }
        guard case .delegateRuns(_, let rows) = ps.all.last else { return XCTFail() }
        XCTAssertEqual(rows.map(\.runID), [myRun])

        for request in [DelegateRequest.stop(run: theirRun), .wait(run: theirRun, timeout: nil, from: nil),
                        .logs(run: theirRun, follow: false, from: nil), .diff(run: theirRun), .apply(run: theirRun),
                        .down(service: theirRun, cwd: "/w/proj")] {
            let refused = send(request)
            try await until { refused.all.contains(where: terminal) }
            guard case .err(_, "not_found", _) = refused.all.last else { return XCTFail("\(request): \(refused.all)") }
        }
        XCTAssertFalse(mini.requests.contains(.runCancel(runID: "h2")))

        // A human shell sees every tab's runs.
        let human = send(.ps, as: .human)
        try await until { human.all.contains(where: terminal) }
        guard case .delegateRuns(_, let all) = human.all.last else { return XCTFail() }
        XCTAssertEqual(Set(all.map(\.runID)), [myRun, theirRun])
    }

    func testRecipeListAddAndCheck() async throws {
        config.config = DelegateConfig(defaultHost: "mini", include: [".env"],
                                       recipes: ["b": Recipe(host: "nowhere", run: "b"), "a": Recipe(run: "a")],
                                       routes: [Route(match: "xcodebuild test *", recipe: "a")])
        let ls = send(.recipeList(cwd: "/w/proj"))
        try await until { ls.all.contains(where: terminal) }
        guard case .recipes(_, let book) = ls.all.last else { return XCTFail() }
        XCTAssertEqual(book.recipes.map(\.name), ["a", "b"])
        XCTAssertEqual(book.routes, [WireRoute(match: "xcodebuild test *", recipe: "a")])

        let check = send(.recipeCheck(cwd: "/w/proj"))
        try await until { check.all.contains(where: terminal) }
        XCTAssertEqual(check.all.last, .recipeCheck(cid: 1, problems: ["b: unknown host nowhere"]))

        let add = send(.recipeAdd(cwd: "/w/proj", name: "c", recipe: WireRecipe(name: "c", run: "make c", apply: "auto")))
        try await until { add.all.contains(where: terminal) }
        XCTAssertEqual(add.all.last, .ack(cid: 1))
        XCTAssertEqual(config.added.first?.1.apply, .auto)
    }

    /// A routed command runs as written, with the route's recipe supplying the host.
    func testARouteRunsTheArgvWithTheRecipesHost() async throws {
        config.config = DelegateConfig(recipes: ["ui": Recipe(host: "mini", run: "ignored")],
                                       routes: [Route(match: "xcodebuild test *", recipe: "ui")])
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", command: ["xcodebuild", "test", "-scheme", "My App"])))
        _ = try await started(frames)
        guard case .runStart(_, let spec, _, _)? = mini.requests.first(where: { Self.op($0) == "run.start" }) else {
            return XCTFail()
        }
        XCTAssertEqual(spec.command, "xcodebuild test -scheme 'My App'")
    }

    func testCommandAndPortComposition() throws {
        XCTAssertEqual(try DelegationService.command(argv: ["make && make test"], recipe: nil, routed: false), "make && make test")
        XCTAssertEqual(try DelegationService.command(argv: ["-only-testing:X Y"], recipe: Recipe(run: "xcodebuild test"), routed: false),
                       "xcodebuild test '-only-testing:X Y'")
        XCTAssertThrowsError(try DelegationService.command(argv: [], recipe: nil, routed: false))
        XCTAssertEqual(try DelegationService.ports(recipe: ["5432", "8080:80"], cli: ["15432:5432"]).map(\.notation),
                       ["8080:80", "15432:5432"])
        XCTAssertThrowsError(try DelegationService.ports(recipe: [], cli: ["a:b"]))
    }

    // MARK: Helpers

    private static func op(_ request: DelegationRequest) -> String {
        let data = try? JSONEncoder().encode(request)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return object?["op"] as? String ?? "?"
    }

    static func tempRepo(ignored: [String], files: [String], gitignore: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-hint-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try Data(gitignore.utf8).write(to: root.appendingPathComponent(".gitignore"))
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "init", "-q"]
        git.currentDirectoryURL = root
        try git.run()
        git.waitUntilExit()
        return root
    }
}
