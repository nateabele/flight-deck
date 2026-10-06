import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

/// The end of a run's life on the controller: a host that forgot it, retention letting it go,
/// and what the service says about the changes it left. Over `DelegationServiceTests`' fakes.
@MainActor
final class DelegationLifecycleTests: XCTestCase {
    private var hosts: FakeHosts!
    private var mini: FakeHostLink!
    private var config: FakeConfig!
    private var results: FakeResults!
    private var directory: URL!
    private var service: DelegationService!
    private let tab = UUID()

    override func setUp() async throws {
        hosts = FakeHosts()
        mini = FakeHostLink(name: "mini")
        hosts.links["mini"] = mini
        config = FakeConfig()
        results = FakeResults()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fd-life-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = makeService(RunRegistry(file: nil))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService(_ registry: RunRegistry) -> DelegationService {
        DelegationService(registry: registry, dependencies: .init(
            hosts: hosts, preflight: FakePreflight(), snapshots: FakeSync(), bundles: FakeSync(), results: results,
            config: config, worktrees: FakeWorktrees(), sessionTitle: { _ in "alpha" },
            sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) },
            directory: directory, replayIdle: 0.05, replayFirstEvent: 0.2))
    }

    private final class Frames { var all: [ServerFrame] = [] }
    private func send(_ request: DelegateRequest) -> Frames {
        let frames = Frames()
        service.handle(request, caller: .session(tab), cid: 1) { frames.all.append($0) }
        return frames
    }

    private func until(_ what: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func started(_ frames: Frames) async throws -> String {
        try await until("delegateStarted") { frames.all.contains { if case .delegateStarted = $0 { return true }; return false } }
        for frame in frames.all { if case .delegateStarted(_, let s) = frame { return s.runID } }
        return ""
    }

    private func isTerminal(_ frame: ServerFrame) -> Bool {
        switch frame {
        case .delegateExit, .err, .ack: return true
        default: return false
        }
    }

    private func record(_ id: String, hostRunID: String = "h1", state: DelegatedRun.State, endedAt: Date?,
                        bundle: String? = nil) -> DelegatedRun {
        var run = DelegatedRun(id: id, hostRunID: hostRunID, host: "mini", owner: nil, kind: .run, command: "make",
                               recipe: nil, state: state, status: state.isFinished ? 0 : nil, ports: [],
                               startedAt: endedAt ?? Date(), worktree: "/w/proj", snapshot: nil, applyMode: .review,
                               request: WireDelegateRun(cwd: "/w/proj"), resultCommit: bundle.map { _ in "c" },
                               resultBundle: bundle)
        run.endedAt = endedAt
        return run
    }

    // MARK: A host that forgot the run

    /// hostd restarted: its runs died with it, and the watcher's `run.attach` is answered
    /// `unknown_run`. The run ends here, as died with 125, or every `wait` on it would hang.
    func testUnknownRunFromTheHostEndsTheRunAsDied() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        let id = try await started(frames)
        mini.fail("h1", DelegationError(code: "unknown_run", message: "mini has no such run"))
        try await until("the run's end") { frames.all.contains(where: self.isTerminal) }
        XCTAssertEqual(frames.all.last, .delegateExit(cid: 1, status: 125))
        XCTAssertTrue(frames.all.contains(.delegateNotice(cid: 1, message: "mini restarted and \(id) is gone — rerun it")),
                      "\(frames.all)")
        XCTAssertEqual(service.registry.run(id)?.state, .died)
        XCTAssertEqual(service.registry.run(id)?.status, 125)
        let waited = send(.wait(run: id, timeout: nil, from: nil))
        try await until { waited.all.contains(where: self.isTerminal) }
        XCTAssertEqual(waited.all.last, .delegateExit(cid: 1, status: 125))
    }

    /// `down` of a service the host no longer has is already done, not a failure.
    func testDownOfAServiceTheHostForgotSucceeds() async throws {
        let up = send(.up(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["postgres"])))
        let id = try await started(up)
        mini.downError = HostLinkError.remote(code: "unknown_run", message: "no service h1")
        let down = send(.down(service: id, cwd: "/w/proj"))
        try await until { down.all.contains(where: self.isTerminal) }
        XCTAssertEqual(down.all, [.ack(cid: 1)])
        XCTAssertEqual(service.registry.run(id)?.state, .exited)
    }

    // MARK: Host run ids reused

    /// A screen held by a run whose host id an older, finished run of ours also had (a host
    /// from before unique run ids, restarted): the notice names the live one.
    func testTheScreenHolderIsTheLiveRunUnderAReusedHostID() async throws {
        let registry = RunRegistry(file: nil)
        registry.add(record(registry.mintID(), hostRunID: "h1", state: .exited, endedAt: Date()))
        service = makeService(registry)
        let holder = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["xcodebuild"], detach: true)))
        let holderID = try await started(holder)
        XCTAssertEqual(service.registry.run(holderID)?.hostRunID, "h1", "the host reused h1")
        let waiter = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["xcodebuild"])))
        _ = try await started(waiter)
        mini.emit("h2", .queued(position: 1, on: .screen, holder: LeaseHolder(runID: "h1", session: "alpha")))
        try await until { waiter.all.contains { if case .delegateNotice = $0 { return true }; return false } }
        XCTAssertTrue(waiter.all.contains(.delegateNotice(
            cid: 1, message: "waiting for mini's screen — held by \(holderID) (session \"alpha\")")), "\(waiter.all)")
    }

    // MARK: Review mode

    /// `apply = "review"` keeps the changes for `diff`/`apply`; the run says it left some.
    func testAReviewRunThatChangedFilesSaysSo() async throws {
        mini.resultCommit = "res1"
        mini.resultBytes = Data("bundle".utf8)
        results.patchText = "diff --git a/x b/x\n+1\ndiff --git a/y b/y\n+2\n"
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        let id = try await started(frames)
        mini.emit("h1", .exited(.code(0)))
        try await until { frames.all.contains(where: self.isTerminal) }
        XCTAssertEqual(Array(frames.all.suffix(2)), [
            .delegateNotice(cid: 1, message: "\(id) changed 2 files — flightdeck diff \(id)"),
            .delegateExit(cid: 1, status: 0),
        ])
    }

    /// The result channel is closed from this side too once it has been read to its end, so
    /// it retires rather than sitting half-open in the mux for the life of the link.
    func testAFetchedResultsChannelIsFinished() async throws {
        mini.resultCommit = "res1"
        mini.resultBytes = Data("bundle".utf8)
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        _ = try await started(frames)
        mini.emit("h1", .exited(.code(0)))
        try await until { frames.all.contains(where: self.isTerminal) }
        XCTAssertEqual(mini.channels.count, 2, "the sync push and the result")
        XCTAssertEqual(mini.channels.map(\.finished), [true, true])
    }

    func testAReviewRunThatChangedNothingSaysNothing() async throws {
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        _ = try await started(frames)
        mini.emit("h1", .exited(.code(0)))
        try await until { frames.all.contains(where: self.isTerminal) }
        XCTAssertFalse(frames.all.contains { if case .delegateNotice = $0 { return true }; return false }, "\(frames.all)")
    }

    // MARK: orphan_timeout

    func testAServiceRecipesOrphanTimeoutReachesTheHost() async throws {
        config.config = DelegateConfig(recipes: [
            "db": Recipe(host: "mini", run: "postgres", service: true, orphanTimeout: 900),
            "build": Recipe(host: "mini", run: "make", orphanTimeout: 900),
        ])
        _ = try await started(send(.up(WireDelegateRun(cwd: "/w/proj", recipe: "db"))))
        _ = try await started(send(.run(WireDelegateRun(cwd: "/w/proj", recipe: "build", detach: true))))
        let specs = mini.requests.compactMap { if case .runStart(_, let spec, _, _) = $0 { return spec } else { return nil } }
        XCTAssertEqual(specs.map(\.orphanTimeout), [900, nil], "only a service outlives a lost controller")
    }

    // MARK: Retention

    /// One place lets a run go: its registry entry, its output copy (through the directory)
    /// and its result bundle and scratch files, together.
    func testRetentionPrunesTheRecordTheCopyAndTheBundle() async throws {
        let old = Date().addingTimeInterval(-15 * 24 * 3600)
        let bundle = directory.appendingPathComponent("r1.bundle")
        let patch = directory.appendingPathComponent("r1.patch")
        let keptBundle = directory.appendingPathComponent("r2.bundle")
        for file in [bundle, patch, keptBundle] { try Data("x".utf8).write(to: file) }
        let registry = RunRegistry(file: nil)
        registry.add(record(registry.mintID(), state: .exited, endedAt: old, bundle: bundle.path))
        registry.add(record(registry.mintID(), hostRunID: "h2", state: .exited, endedAt: Date(), bundle: keptBundle.path))
        registry.add(record(registry.mintID(), hostRunID: "h3", state: .running, endedAt: nil))

        service = makeService(registry)
        XCTAssertEqual(service.registry.runs.map(\.id), ["r2", "r3"])
        XCTAssertEqual(hosts.forgotten.map(\.id), ["r1"], "its output copy")
        try await until("files deleted") { !FileManager.default.fileExists(atPath: bundle.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: patch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptBundle.path))
    }

    /// A run's end is when retention starts counting, and a run that ends prunes what has expired.
    func testARunEndingPrunesWhatExpired() async throws {
        let registry = RunRegistry(file: nil)
        registry.add(record(registry.mintID(), hostRunID: "h0", state: .exited, endedAt: Date()))
        service = makeService(registry)
        XCTAssertNotNil(service.registry.run("r1"), "ended just now: kept")
        let frames = send(.run(WireDelegateRun(cwd: "/w/proj", host: "mini", command: ["make"])))
        let id = try await started(frames)
        XCTAssertNil(service.registry.run(id)?.endedAt)
        service.registry.update("r1") { $0.endedAt = Date().addingTimeInterval(-15 * 24 * 3600) }
        mini.emit("h1", .exited(.code(0)))
        try await until { frames.all.contains(where: self.isTerminal) }
        XCTAssertNil(service.registry.run("r1"), "pruned when the next run ended")
        XCTAssertNotNil(service.registry.run(id)?.endedAt, "stamped as it ended")
    }

    /// At launch the directory loses what names no run: copies under the old
    /// `<slot>-<host run id>.out` names, provisional copies, and a pruned run's files.
    func testLaunchSweepsFilesForNoRun() async throws {
        let names = ["r1.out", "r1.bundle", "r9.out", "r9.bundle", "SLOT-h1.out", "pending-SLOT-h4.out", "notes.txt"]
        for name in names { try Data("x".utf8).write(to: directory.appendingPathComponent(name)) }
        let registry = RunRegistry(file: nil)
        registry.add(record(registry.mintID(), state: .exited, endedAt: Date()))
        service = makeService(registry)
        try await until("the sweep") {
            (try? FileManager.default.contentsOfDirectory(atPath: self.directory.path).sorted())
                == ["notes.txt", "r1.bundle", "r1.out"]
        }
    }
}

/// `orphan_timeout` in `delegate.toml`, through C4's parser and writer.
final class RecipeOrphanTimeoutTests: XCTestCase {
    private func parse(_ toml: String) throws -> DelegateConfig? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-orphan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = DelegateConfigParser.fileURL(projectRoot: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try toml.write(to: file, atomically: true, encoding: .utf8)
        return try DelegateConfigParser.load(projectRoot: root)?.config
    }

    func testOrphanTimeoutParsesAndValidates() throws {
        let config = try parse("[recipe.db]\nrun = \"postgres\"\nservice = true\norphan_timeout = 900\n")
        XCTAssertEqual(config?.recipes["db"]?.orphanTimeout, 900)
        XCTAssertNil(try parse("[recipe.db]\nrun = \"postgres\"\n")?.recipes["db"]?.orphanTimeout, "the host's default")
        let zero = DelegateConfig(recipes: ["db": Recipe(run: "postgres", service: true, orphanTimeout: 0)])
        XCTAssertTrue(zero.validate().contains { $0.description.contains("orphan_timeout must be at least 1") },
                      "\(zero.validate())")
    }

    func testRecipeAddWritesOrphanTimeoutBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-orphan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RecipeWriter.add(name: "db", recipe: Recipe(run: "postgres", service: true, orphanTimeout: 600), projectRoot: root)
        XCTAssertEqual(try DelegateConfigParser.load(projectRoot: root)?.config.recipes["db"]?.orphanTimeout, 600)
    }
}
