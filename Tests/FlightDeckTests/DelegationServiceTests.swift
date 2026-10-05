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

/// A host, keeping exactly the `HostLinking.events` contract C8's adapter must (ruling 6):
/// events buffered from the start, any number of concurrent subscribers each from its own
/// offset, a chunk straddling the offset cut to start there, and replay in the order state,
/// output, end.
@MainActor
final class FakeHostLink: HostLinking {
    let name: String
    var isConnected = true
    var requests: [DelegationRequest] = []
    var nextRun = 0
    /// Bytes the next pulled channel (`run.result`/`run.artifacts`) will carry.
    var resultBytes: Data?
    var resultCommit: String?
    var nextChannel: ChannelID = 1
    /// Thrown by the next `run.start`, as a host `err` reaches the controller.
    var failStart: Error?
    var channels: [FakeByteChannel] = []
    private var events: [String: [RunEvent]] = [:]
    private var continuations: [String: [UUID: (Int64, AsyncThrowingStream<RunEvent, Error>.Continuation)]] = [:]
    /// How many subscriptions are open per run, for the fan-out test.
    func subscribers(_ runID: String) -> Int { continuations[runID]?.count ?? 0 }

    init(name: String) { self.name = name }

    func request(_ request: DelegationRequest) async throws -> DelegationReply {
        requests.append(request)
        switch request {
        case .syncTips: return .syncTips(tips: [])
        case .syncPush: return .syncPush
        case .runStart:
            if let failStart { throw failStart }
            nextRun += 1
            return .runStart(runID: "h\(nextRun)")
        case .runCancel: return .runCancel
        case .runResult: return .runResult(commit: resultCommit)
        case .runArtifacts: return .runArtifacts(found: false)
        case .serviceDown(let id):
            emit(id, .exited(.signal(15)))
            return .serviceDown
        case .serviceSync: return .serviceSync
        case .portOpen: return .portOpen
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
                let history = self.events[runID, default: []]
                // State first, then output, then the end (A2's replay order).
                let state = history.filter { if case .queued = $0 { return true }; if case .started = $0 { return true }; return false }
                for event in state.suffix(1) + history.filter({ if case .output = $0 { return true }; return false }) {
                    Self.deliver(event, from: offset, to: continuation)
                }
                if let end = history.first(where: Self.isEnd) {
                    continuation.yield(end)
                    return continuation.finish()
                }
                let key = UUID()
                self.continuations[runID, default: [:]][key] = (offset, continuation)
                // A cancelled subscriber's stream ends and frees its slot (the contract's
                // "Cancellation"), which is what lets a test count what is still subscribed.
                continuation.onTermination = { _ in
                    Task { @MainActor in self.continuations[runID]?[key] = nil }
                }
            }
        }
    }

    func emit(_ runID: String, _ event: RunEvent) {
        events[runID, default: []].append(event)
        for (offset, continuation) in continuations[runID, default: [:]].values {
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
        guard case .output(let stream, let at, let data) = event else {
            continuation.yield(event)
            return
        }
        let end = at + Int64(data.count)
        guard end > offset else { return }
        let skip = Int(max(0, offset - at))
        continuation.yield(.output(stream: stream, offset: at + Int64(skip), data: Data(data.dropFirst(skip))))
    }
}

@MainActor
final class FakeHosts: DelegationHostDirectory {
    var links: [String: FakeHostLink] = [:]
    var hostNames: [String] { links.keys.sorted() }
    func link(named name: String) throws -> any HostLinking {
        guard let link = links[name] else {
            throw DelegationError(code: "host_offline", message: "\(name) is offline (last seen 4m ago)")
        }
        return link
    }
}

final class FakeReservation: PortReservation, @unchecked Sendable {
    let forwards: [PortForward]
    var released = 0
    /// What `startForwarding` was handed: one opener per remote port.
    var opener: ((UInt16) -> any ChannelOpening)?
    init(forwards: [PortForward] = []) { self.forwards = forwards }
    func startForwarding(_ connect: @escaping @Sendable (UInt16) -> any ChannelOpening) { opener = connect }
    func release() { released += 1 }
}

final class FakePreflight: Preflighting {
    var failure: DelegationError?
    var plans: [DelegationPlan] = []
    var reservations: [FakeReservation] = []
    var forwards: [PortForward] = []
    func preflight(_ plan: DelegationPlan, link: any HostLinking) async throws -> any PortReservation {
        plans.append(plan)
        if let failure { throw failure }
        let reservation = FakeReservation(forwards: forwards)
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

final class FakeResults: ResultApplying, @unchecked Sendable {
    /// What `apply` answers when conflicts are not allowed (auto) and when they are.
    var autoOutcome: ApplyOutcome = .clean
    var applied: [(commit: String, allowConflicts: Bool)] = []
    var patchText = "diff --git a/x b/x\n"
    /// Whether each call ran off the main thread, as the protocol promises the app.
    var ranOnMain: [Bool] = []
    /// How long `apply` takes, to let a racing replay show itself.
    var applyDelay: UInt64 = 0
    func patch(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL) async throws -> String {
        ranOnMain.append(Thread.isMainThread)
        return patchText
    }
    func apply(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL, allowConflicts: Bool) async throws -> ApplyOutcome {
        ranOnMain.append(Thread.isMainThread)
        if applyDelay > 0 { try await Task.sleep(nanoseconds: applyDelay) }
        applied.append((commit, allowConflicts))
        return allowConflicts ? .clean : autoOutcome
    }
    func extractArtifacts(tar: URL, into worktree: URL) async throws {}
}

final class FakeConfig: DelegateConfigLoading {
    var config: DelegateConfig?
    var added: [(String, Recipe)] = []
    func load(worktree: URL) throws -> DelegateConfig? { config }
    func add(_ recipe: Recipe, named name: String, worktree: URL) throws { added.append((name, recipe)) }
    func problems(in config: DelegateConfig, hosts: [String]) -> [String] {
        config.recipes.compactMap { name, r in r.host.flatMap { hosts.contains($0) ? nil : "\(name): unknown host \($0)" } }
    }
}

struct FakeWorktrees: WorktreeLocating {
    var root = URL(fileURLWithPath: "/w/proj")
    func locate(cwd: URL) async throws -> (worktree: URL, subdir: String) { (root, "") }
    func ignored(_ paths: [String], in worktree: URL) async -> Set<String> { [] }
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

    private func dependencies(worktrees: any WorktreeLocating = FakeWorktrees()) -> DelegationService.Dependencies {
        .init(
            hosts: hosts, preflight: preflight, snapshots: sync, bundles: sync, results: results,
            config: config, worktrees: worktrees, sessionTitle: { _ in "alpha" },
            // Records the bound; a short one elapses at once, a long one (the 9-minute default)
            // never does within a test, so a wait that should end on its own still can.
            sleep: { [weak self] seconds in
                self?.waitTimeouts.append(seconds)
                if seconds >= 60 { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("fd-deleg-\(UUID().uuidString)"),
            replayIdle: 0.05, replayFirstEvent: 0.2)
    }

    private func makeService(worktrees: any WorktreeLocating) {
        service = DelegationService(registry: RunRegistry(file: nil), dependencies: dependencies(worktrees: worktrees))
    }

    /// Sends one request and collects every frame it draws.
    private final class Frames { var all: [ServerFrame] = [] }
    private func send(_ request: DelegateRequest, as caller: ControlCaller? = nil,
                      cancellation: ReplyCancellation? = nil) -> Frames {
        let frames = Frames()
        service.handle(request, caller: caller ?? .session(tab), cid: 1, cancellation: cancellation) { frames.all.append($0) }
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
        preflight.failure = DelegationError(code: "local_port_held", message: line)
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
        preflight.forwards = [PortForward(local: 15432, remote: 5432)]
        let up = send(.up(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["postgres"], ports: ["15432:5432"])))
        let id = try await started(up)
        XCTAssertEqual(up.all.last, .delegateStarted(cid: 1, WireDelegateStarted(
            runID: id, host: "mini", ports: [WirePortBinding(local: 15432, remote: 5432)])))
        XCTAssertNotNil(preflight.reservations.first?.opener, "a service's forwards start serving")
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

    func testCommandComposition() throws {
        XCTAssertEqual(try DelegationService.command(argv: ["make && make test"], recipe: nil, routed: false), "make && make test")
        XCTAssertEqual(try DelegationService.command(argv: ["-only-testing:X Y"], recipe: Recipe(run: "xcodebuild test"), routed: false),
                       "xcodebuild test '-only-testing:X Y'")
        XCTAssertThrowsError(try DelegationService.command(argv: [], recipe: nil, routed: false))
    }

    // MARK: Fix round 1

    /// A `long` recipe run without `detach` streams to its end: only the request's `detach`
    /// (or `up`) ends a stream on `delegateStarted`, so the app and the CLI can never disagree.
    func testOnlyTheRequestsDetachEndsAStreamOnStarted() async throws {
        config.config = DelegateConfig(recipes: ["ui": Recipe(host: "mini", run: "xcodebuild test", long: true)])
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", recipe: "ui")))
        _ = try await started(frames)
        mini.emit(hostRunID(), .exited(.code(5)))
        try await until { frames.all.contains(where: terminal) }
        XCTAssertEqual(frames.all.last, .delegateExit(cid: 1, status: 5))
    }

    /// `exec` never routes: it runs the argv in the existing checkout, as given.
    func testExecNeverRoutes() async throws {
        config.config = DelegateConfig(defaultHost: "mini",
                                       recipes: ["ui": Recipe(host: "elsewhere", run: "x", long: true)],
                                       routes: [Route(match: "xcodebuild *", recipe: "ui")])
        let frames = send(.exec(WireDelegateRun(cwd: "/w/proj", command: ["xcodebuild", "build"])))
        _ = try await started(frames)
        XCTAssertNil(service.registry.runs.first?.recipe)
        XCTAssertEqual(service.registry.runs.first?.host, "mini")
    }

    func testApplyWithNoResultSaysSo() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        let id = try await started(frames)
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { frames.all.contains(where: terminal) }
        let applied = send(.apply(run: id))
        try await until { applied.all.contains(where: terminal) }
        guard case .err(_, "nothing_to_apply", let message?) = applied.all.last else { return XCTFail("\(applied.all)") }
        XCTAssertTrue(message.contains(id), message)
    }

    /// A host line already names the host; it is never prefixed a second time.
    func testAHostLineIsNotPrefixedTwice() async throws {
        mini.failStart = HostLinkError.remote(code: "no_console_user", message: "x")
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        try await until { frames.all.contains(where: terminal) }
        XCTAssertEqual(frames.all.last, .err(cid: 1, code: "no_console_user",
                                             message: "nobody is logged in at mini's console — log in there, then rerun"))
    }

    /// After a relaunch the app has no live watcher; `logs` still replays what the host spooled.
    func testLogsAfterARelaunchReplaysTheSpool() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fd-reg-\(UUID().uuidString).json")
        service = DelegationService(registry: RunRegistry(file: file), dependencies: dependencies())
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 0, data: Data("built".utf8)))

        service = DelegationService(registry: RunRegistry(file: file), dependencies: dependencies())
        let logs = send(.logs(run: id, follow: false, from: nil))
        try await until { logs.all.contains(where: terminal) }
        XCTAssertEqual(logs.all, [.delegateOutput(cid: 1, stream: "stdout", offset: 0, data: Data("built".utf8)), .ack(cid: 1)])
    }

    /// A restarted service stays the tab's, even when a human shell restarts it.
    func testRestartKeepsTheOwner() async throws {
        let up = send(.up(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["db"])))
        let id = try await started(up)
        let restarted = send(.restart(service: id, cwd: "/w/proj"), as: .human)
        try await until { restarted.all.count == 1 }
        XCTAssertEqual(service.registry.runs.last?.owner, tab)
    }

    /// A reattaching `run` (`noTimeout`) waits as long as the run takes: no 540 s, no 124.
    func testAReattachHasNoTimeout() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 0, data: Data("ab".utf8)))
        let resumed = send(.wait(run: id, timeout: nil, from: 1, noTimeout: true))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(waitTimeouts.isEmpty, "no timer at all: \(waitTimeouts)")
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { resumed.all.contains(where: terminal) }
        XCTAssertEqual(resumed.all, [.delegateOutput(cid: 1, stream: "stdout", offset: 1, data: Data("b".utf8)),
                                     .delegateExit(cid: 1, status: 0)])
    }

    /// Ruling 6: an attached run, a `wait {from}` and the monitor all subscribe to one run at
    /// once, each from its own offset, and none sees another's bytes.
    func testConcurrentSubscriptionsKeepTheirOwnOffsets() async throws {
        let attached = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        let id = try await started(attached)
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 0, data: Data("0123".utf8)))
        let late = send(.wait(run: id, timeout: nil, from: 2, noTimeout: true))
        try await until { self.mini.subscribers(self.hostRunID()) == 2 }
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 4, data: Data("45".utf8)))
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { attached.all.contains(where: terminal) && late.all.contains(where: terminal) }
        let bytes = { (frames: Frames) in frames.all.compactMap { frame -> String? in
            if case .delegateOutput(_, _, _, let data) = frame { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined() }
        XCTAssertEqual(bytes(attached), "012345")
        XCTAssertEqual(bytes(late), "2345")
    }

    func testWaitSurfacesNoticesAndADownedServiceEndsIt() async throws {
        let up = send(.up(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["db"])))
        let id = try await started(up)
        let waited = send(.wait(run: id, timeout: nil, from: nil))
        try await until { self.waitTimeouts.count == 1 }
        mini.emit(hostRunID(), .queued(position: 1, on: .slot, holder: nil))
        try await until { waited.all.count == 1 }
        XCTAssertEqual(waited.all.first, .delegateNotice(cid: 1, message: "waiting for a free checkout on mini"))
        let down = send(.down(service: id, cwd: "/w/proj"))
        try await until { down.all.contains(where: terminal) && waited.all.contains(where: terminal) }
        XCTAssertEqual(waited.all.last, .delegateExit(cid: 1, status: 0))
    }

    /// The hint skips a file under an included directory, and never fires for `exec`, which
    /// sent nothing at all.
    func testHintRespectsDirectoryIncludesAndSkipsExec() async throws {
        let repo = try Self.tempRepo(ignored: [], files: ["config/secrets.json", ".env"], gitignore: "config/\n.env\n")
        makeService(worktrees: GitWorktreeLocator())
        for request in [DelegateRequest.run(WireDelegateRun(cwd: repo.path, host: "mini", command: ["make"], include: ["config/"])),
                        .exec(WireDelegateRun(cwd: repo.path, host: "mini", command: ["make"]))] {
            let frames = send(request)
            _ = try await started(frames)
            mini.emit(hostRunID(), .output(stream: .stderr, offset: 0, data: Data("open config/secrets.json: missing; .env: exec".utf8)))
            mini.emit(hostRunID(), .exited(.code(1)))
            try await until { frames.all.contains(where: terminal) }
            if case .run = request {
                // config/secrets.json was sent under `config/`; `.env` was not.
                guard case .err(_, "missing_include", let message?) = frames.all.last else { return XCTFail("\(frames.all)") }
                XCTAssertTrue(message.contains(".env is ignored"), message)
            } else {
                XCTAssertEqual(frames.all.last, .delegateExit(cid: 1, status: 1))
            }
        }
    }

    func testSyncWithRestartOnSyncAnswersAsRestartDoes() async throws {
        config.config = DelegateConfig(recipes: ["db": Recipe(host: "mini", run: "postgres", service: true, restartOnSync: true)])
        let up = send(.up(WireDelegateRun(cwd: "/w/proj", recipe: "db")))
        let id = try await started(up)
        let synced = send(.sync(service: id, cwd: "/w/proj"), as: .human)
        try await until { synced.all.count == 1 }
        guard case .delegateStarted(_, let started) = synced.all.last else { return XCTFail("\(synced.all)") }
        XCTAssertNotEqual(started.runID, id)
        XCTAssertEqual(service.registry.run(started.runID)?.owner, tab, "the tab's service, whoever synced it")
    }

    func testResultWorkRunsOffTheMainActor() async throws {
        mini.resultCommit = "res1"
        mini.resultBytes = Data("bundle".utf8)
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        let id = try await started(frames)
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until { frames.all.contains(where: terminal) }
        let diff = send(.diff(run: id))
        try await until { diff.all.contains(where: terminal) }
        let applied = send(.apply(run: id))
        try await until { applied.all.contains(where: terminal) }
        XCTAssertEqual(results.ranOnMain, [false, false])
    }

    /// A service's forwards open `port.open` channels named for its host run.
    func testAServicesForwardOpensPortChannels() async throws {
        preflight.forwards = [PortForward(local: 15432, remote: 5432)]
        let up = send(.up(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["db"], ports: ["15432:5432"])))
        _ = try await started(up)
        let opener = try XCTUnwrap(preflight.reservations.first?.opener)
        let channel = try await opener(5432).open()
        XCTAssertEqual(mini.requests.last, .portOpen(service: hostRunID(), remote: 5432, channel: channel.id))
    }

    /// Every run still going is watched again at launch, so its end is recorded unasked.
    func testALaunchWatchesRunsStillGoing() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fd-reg-\(UUID().uuidString).json")
        service = DelegationService(registry: RunRegistry(file: file), dependencies: dependencies())
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        service = DelegationService(registry: RunRegistry(file: file), dependencies: dependencies())
        mini.emit(hostRunID(), .exited(.code(7)))
        try await until { self.service.registry.run(id)?.status == 7 }
    }

    // MARK: Fix round 2

    /// Three resumes, then the reader goes: no replay outlives its reader, and the host link
    /// is left with the monitor's subscription alone.
    func testResumesLeaveNoReplayRunningOnceTheirReaderIsGone() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 0, data: Data("abc".utf8)))
        var readers: [ReplyCancellation] = []
        for from in [Int64(0), 1, 2] {
            let reader = ReplyCancellation()
            readers.append(reader)
            _ = send(.wait(run: id, timeout: nil, from: from, noTimeout: true), cancellation: reader)
        }
        try await until("three replays") { self.service.activeReplays == 3 }
        readers.forEach { $0.cancel() }
        try await until("replays gone") { self.service.activeReplays == 0 && self.mini.subscribers(self.hostRunID()) == 1 }
    }

    /// A resumed run exits only once the run is finished here: its auto-applied changes are in
    /// the worktree first, as they are for the attached run.
    func testAResumedRunExitsAfterItsResultIsApplied() async throws {
        config.config = DelegateConfig(recipes: ["gen": Recipe(host: "mini", run: "make gen", apply: .auto)])
        mini.resultCommit = "res1"
        mini.resultBytes = Data("bundle".utf8)
        results.applyDelay = 100_000_000
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", recipe: "gen", detach: true)))
        let id = try await started(frames)
        let resumed = send(.wait(run: id, timeout: nil, from: 0, noTimeout: true))
        var appliedAtExit: Int?
        mini.emit(hostRunID(), .exited(.code(0)))
        try await until("exit") {
            if appliedAtExit == nil, resumed.all.contains(where: terminal) { appliedAtExit = results.applied.count }
            return appliedAtExit != nil
        }
        XCTAssertEqual(resumed.all.last, .delegateExit(cid: 1, status: 0))
        XCTAssertEqual(appliedAtExit, 1, "the changes were applied before the CLI was told the run ended")
    }

    /// A non-following `logs` stops at the output end it saw when it began, not at whatever
    /// arrives while it replays.
    func testLogsStopsAtTheEndItSawWhenItBegan() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 0, data: Data("abc".utf8)))
        try await Task.sleep(nanoseconds: 20_000_000)
        let logs = send(.logs(run: id, follow: false, from: nil))
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 3, data: Data("def".utf8)))
        try await until { logs.all.contains(where: terminal) }
        XCTAssertEqual(logs.all, [.delegateOutput(cid: 1, stream: "stdout", offset: 0, data: Data("abc".utf8)), .ack(cid: 1)])
    }

    /// A dropped link is never reused: the next request goes to the directory's current one.
    func testADeadLinkIsReplacedFromTheDirectory() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        mini.isConnected = false
        let fresh = FakeHostLink(name: "mini")
        hosts.links["mini"] = fresh
        let stopped = send(.stop(run: id))
        try await until { stopped.all.contains(where: terminal) }
        XCTAssertEqual(stopped.all.last, .ack(cid: 1))
        XCTAssertEqual(fresh.requests, [.runCancel(runID: "h1")])
    }

    /// A run that finished before a relaunch: a reattach answers its code at once, rather than
    /// waiting on an end nothing will ever publish.
    func testAReattachToARunThatEndedBeforeARelaunchAnswersAtOnce() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fd-reg-\(UUID().uuidString).json")
        service = DelegationService(registry: RunRegistry(file: file), dependencies: dependencies())
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"], detach: true)))
        let id = try await started(frames)
        mini.emit(hostRunID(), .output(stream: .stdout, offset: 0, data: Data("x".utf8)))
        mini.emit(hostRunID(), .exited(.code(3)))
        try await until { self.service.registry.run(id)?.status == 3 }

        // The relaunched app's link has none of the old events (no mirror, the host's spool
        // gone): nothing will replay the end, so only the record can supply it.
        hosts.links["mini"] = FakeHostLink(name: "mini")
        service = DelegationService(registry: RunRegistry(file: file), dependencies: dependencies())
        let resumed = send(.wait(run: id, timeout: 600, from: 1))
        try await until { resumed.all.contains(where: terminal) }
        XCTAssertEqual(resumed.all.last, .delegateExit(cid: 1, status: 3))
        XCTAssertEqual(resumed.all.count, 1, "\(resumed.all)")
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
