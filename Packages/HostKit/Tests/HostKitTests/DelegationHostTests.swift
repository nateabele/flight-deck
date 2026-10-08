import Foundation
import XCTest
@testable import HostKit

/// One controller connection to a `HostServerCore` with a real router behind it, in memory:
/// text requests go through a serial queue (the transport's per-connection queue), binary
/// frames straight in (the transport's delivery thread), and the controller's own `ChannelMux`
/// sits on the other end of the peer's binary half.
private final class Controller: HostPeer, @unchecked Sendable {
    let slot: UUID
    private let core: HostServerCore
    private let queue = DispatchQueue(label: "test.peer")
    private let lock = NSLock()
    private var frames: [HostServerFrame] = []
    private var nextID = 1
    private(set) var mux: ChannelMux!

    init(core: HostServerCore, slot: UUID = UUID()) {
        self.core = core
        self.slot = slot
        mux = ChannelMux(role: .controller) { [unowned self] data in core.receive(binary: data, from: self) }
    }

    func send(text: String) {
        guard let frame = try? HostWire.decode(HostServerFrame.self, from: text) else { return }
        lock.withLock { frames.append(frame) }
    }

    func send(binary: Data) { mux.receive(binary: binary) }
    func close() {}

    func hello() async throws -> [HostCapability] {
        deliver(.hello(protocolVersion: .current, capabilities: [.hostInfo], controllerName: "laptop"))
        let ack = try await wait("helloAck") { if case .helloAck = $0 { return true }; return false }
        guard case .helloAck(_, let caps, _, _) = ack else { throw CocoaError(.featureUnsupported) }
        return caps
    }

    /// Sends a request and returns its id without waiting.
    func post(_ request: HostRequest) -> Int {
        let id = lock.withLock { () -> Int in defer { nextID += 1 }; return nextID }
        deliver(.request(id: id, request))
        return id
    }

    func reply(to id: Int, timeout: TimeInterval = 30) async throws -> HostReply {
        let frame = try await wait("reply \(id)", timeout: timeout) {
            switch $0 {
            case .reply(id, _), .error(id, _, _): return true
            default: return false
            }
        }
        if case .error(_, let code, let message) = frame { throw Remote(code: code, message: message) }
        guard case .reply(_, let reply) = frame else { throw CocoaError(.featureUnsupported) }
        return reply
    }

    func request(_ request: DelegationRequest) async throws -> DelegationReply {
        guard case .delegation(let reply) = try await self.reply(to: post(.delegation(request))) else {
            throw CocoaError(.featureUnsupported)
        }
        return reply
    }

    /// Every event of `runID` received so far, until (and including) its end.
    func events(_ runID: String, timeout: TimeInterval = 30) async throws -> [RunEvent] {
        _ = try await wait("end of \(runID)", timeout: timeout) {
            if case .event(runID, .exited) = $0 { return true }
            if case .event(runID, .serviceDied) = $0 { return true }
            return false
        }
        return lock.withLock {
            frames.compactMap { if case .event(runID, let ev) = $0 { return ev }; return nil }
        }
    }

    func started(_ runID: String) async throws {
        _ = try await wait("start of \(runID)") { if case .event(runID, .started) = $0 { return true }; return false }
    }

    func forgetFrames() { lock.withLock { frames = [] } }

    func closeConnection() { queue.sync { core.peerClosed(self) } }

    private func deliver(_ frame: HostClientFrame) {
        let text = try! HostWire.encode(frame)
        queue.async { [core] in core.receive(text: text, from: self) }
    }

    private func wait(_ what: String, timeout: TimeInterval = 30,
                      _ match: @escaping (HostServerFrame) -> Bool) async throws -> HostServerFrame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = lock.withLock({ frames.first(where: match) }) { return hit }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Timeout(what: what)
    }

    struct Remote: Error, Equatable { let code: String; let message: String }
    struct Timeout: Error { let what: String }
}

final class DelegationHostTests: XCTestCase {
    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.resolvingSymlinksInPath()
    }

    /// A core with the real router: a real `Runner` and `Workspace` under a temp state root.
    private func host(probe: HostInfoProbe? = nil) throws -> HostServerCore {
        let root = try tempDir("fd-host")
        let workspace = Workspace(root: root)
        let screen = ScreenLease()
        let runner = Runner(runsRoot: root.appendingPathComponent("runs"), shell: "/bin/sh",
                            hostEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSTemporaryDirectory()],
                            power: NoPowerAssertions(), console: UnsupportedConsoleSession(), screen: screen,
                            lifecycle: .workspace(workspace))
        let delegation = DelegationHost(runner: runner, workspace: workspace, screen: screen,
                                        portCheck: PortCheck(run: { _, _ in nil }), screenSupported: false)
        return HostServerCore(hostName: { "mini" },
                              probe: probe ?? HostInfoProbe(stateRoot: root, hostdVersion: "t") { _, _ in nil },
                              delegation: delegation)
    }

    private func repo() throws -> TempRepo {
        let repo = try TempRepo()
        repo.write(".gitignore", "build/\n")
        repo.write("a.txt", "alpha\n")
        try repo.commitAll()
        return repo
    }

    /// `flightdeck run`'s sync, as the controller does it: tips, a bundle of what the host
    /// lacks, written on a fresh channel the `sync.push` names.
    @discardableResult
    private func sync(_ repo: TempRepo, over c: Controller) async throws -> SnapshotRef {
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        guard case .syncTips(let tips) = try await c.request(.syncTips(repoRoot: ref.repoRoot, wtKey: ref.wtKey)) else {
            throw CocoaError(.featureUnsupported)
        }
        let bundle = try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: tips)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let channel = try await c.mux.open()
        let id = c.post(.delegation(.syncPush(ref: ref, channel: channel.id)))
        try await channel.write(try Data(contentsOf: bundle))
        await channel.finish()
        let pushed = try await c.reply(to: id)
        XCTAssertEqual(pushed, .delegation(.syncPush))
        return ref
    }

    private func spec(_ command: String) -> RunSpec {
        RunSpec(command: command, subdir: "", env: [:], pty: false, screen: false, service: false,
                downCommand: nil, ports: [])
    }

    private func start(_ command: String, _ ref: SnapshotRef, apply: Bool = true, over c: Controller) async throws -> String {
        guard case .runStart(let runID) = try await c.request(.runStart(ref: ref, spec: spec(command), owner: "tab", apply: apply)) else {
            throw CocoaError(.featureUnsupported)
        }
        return runID
    }

    /// `run.result`'s bundle, read off its channel while the request is answered.
    private func result(_ runID: String, over c: Controller) async throws -> (commit: String?, bytes: Data) {
        let channel = try await c.mux.open()
        async let bytes: Data = {
            var all = Data()
            while let chunk = try await channel.read() { all.append(chunk) }
            return all
        }()
        let reply: DelegationReply
        do {
            reply = try await c.request(.runResult(runID: runID, channel: channel.id))
        } catch {
            channel.cancel()
            _ = try? await bytes
            throw error
        }
        guard case .runResult(let commit) = reply else { throw CocoaError(.featureUnsupported) }
        return (commit, try await bytes)
    }

    private func output(_ events: [RunEvent]) -> String {
        events.reduce(into: "") { if case .output(_, _, let data) = $1 { $0 += String(decoding: data, as: UTF8.self) } }
    }

    private func remote<T>(_ body: () async throws -> T) async -> String? {
        (await thrown(body) as? Controller.Remote)?.code
    }

    // MARK: -

    func testHelloAdvertisesTheDelegationCapabilities() async throws {
        let c = Controller(core: try host())
        let caps = try await c.hello()
        XCTAssertEqual(Set(caps), [.hostInfo, .run, .sync, .service, .submodules], "no screen on a host that has none")
    }

    func testSyncThenRunStreamsOutputAndExitCode() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)

        let runID = try await start("cat a.txt; echo to-err >&2; exit 3", ref, over: c)
        let events = try await c.events(runID)
        XCTAssertEqual(events.first, .started(runID: runID))
        XCTAssertTrue(output(events).contains("alpha\n"), output(events))
        XCTAssertTrue(output(events).contains("to-err\n"), output(events))
        XCTAssertEqual(events.last, .exited(.code(3)))
    }

    /// Ruling 24: the host keeps a sent result until the controller acks it, so a transfer
    /// that ended before the controller stored the bytes can simply be asked for again.
    func testResultBundleIsKeptUntilTheControllerAcksIt() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let runID = try await start("echo edited > a.txt", ref, over: c)
        let ended = try await c.events(runID)
        XCTAssertEqual(ended.last, .exited(.code(0)))

        let (commit, bytes) = try await result(runID, over: c)
        let file = try tempDir("result").appendingPathComponent("r.bundle")
        try bytes.write(to: file)
        let heads = try TempRepo.git(["bundle", "list-heads", file.path], in: repo.url)
        XCTAssertEqual(heads.split(separator: " ").first.map(String.init), try XCTUnwrap(commit))

        // Sent in full but not acked: the controller may not have stored it, so it is still there.
        let resent = try await result(runID, over: c)
        XCTAssertEqual(resent.commit, commit)
        XCTAssertEqual(resent.bytes, bytes)

        let acked = try await c.request(.runAck(runID: runID, repoRoot: ref.repoRoot))
        XCTAssertEqual(acked, .runAck)
        // Acked, so gone: asking again is `result_expired`, not a second copy of the same edits.
        let again = await remote { try await self.result(runID, over: c) }
        XCTAssertEqual(again, "result_expired")
    }

    /// An ack naming only the run (the lenient shape) finds the repo from the run itself; one
    /// from another controller neither drops the result nor confirms the run exists.
    func testAckWithoutRepoRootAndAForeignAck() async throws {
        let repo = try repo()
        let core = try host()
        let mine = Controller(core: core), theirs = Controller(core: core)
        _ = try await mine.hello()
        _ = try await theirs.hello()
        let ref = try await sync(repo, over: mine)
        let runID = try await start("echo edited > a.txt", ref, over: mine)
        _ = try await mine.events(runID)
        _ = try await result(runID, over: mine)

        let foreign = await remote { try await theirs.request(.runAck(runID: runID, repoRoot: ref.repoRoot)) }
        XCTAssertEqual(foreign, "unknown_run")
        let kept = try await result(runID, over: mine)
        XCTAssertNotNil(kept.commit, "a foreign ack dropped the result")

        let acked = try await mine.request(.runAck(runID: runID, repoRoot: nil))
        XCTAssertEqual(acked, .runAck)
        let again = await remote { try await self.result(runID, over: mine) }
        XCTAssertEqual(again, "result_expired")
    }

    func testRunThatChangedNothingHasNoResult() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let runID = try await start("true", ref, over: c)
        _ = try await c.events(runID)
        let (commit, bytes) = try await result(runID, over: c)
        XCTAssertNil(commit)
        XCTAssertTrue(bytes.isEmpty)
    }

    /// `exec`: no sync, no apply; the run sees the worktree's existing checkout.
    func testExecRunsInTheExistingCheckoutWithoutSyncing() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        _ = try await c.events(try await start("mkdir -p build && echo left-behind > build/out.txt", ref, over: c))

        // The controller's view moved on (a commit the host never got); exec does not care.
        let unseen = SnapshotRef(repoRoot: ref.repoRoot, wtKey: ref.wtKey, worktreeName: ref.worktreeName,
                                 commit: String(repeating: "1", count: 40), tree: String(repeating: "2", count: 40))
        let execID = try await start("cat a.txt build/out.txt", unseen, apply: false, over: c)
        let events = try await c.events(execID)
        XCTAssertEqual(output(events), "alpha\nleft-behind\n")
        XCTAssertEqual(events.last, .exited(.code(0)))

        // A worktree never synced here is refused by the request itself.
        let never = SnapshotRef(repoRoot: ref.repoRoot, wtKey: "0000feed", worktreeName: "other",
                                commit: ref.commit, tree: ref.tree)
        let code = await remote { try await self.start("true", never, apply: false, over: c) }
        XCTAssertEqual(code, "no_checkout")
    }

    func testAttachFromAnOffsetResumesThere() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let runID = try await start("printf 0123456789", ref, over: c)
        let first = try await c.events(runID)
        XCTAssertEqual(output(first), "0123456789")

        c.forgetFrames()
        let attached = try await c.request(.runAttach(runID: runID, offset: 4))
        XCTAssertEqual(attached, .runAttach)
        let events = try await c.events(runID)
        XCTAssertEqual(output(events), "456789")
        guard case .output(_, let offset, _) = events.first(where: { if case .output = $0 { return true }; return false })
        else { return XCTFail("\(events)") }
        XCTAssertEqual(offset, 4)
        XCTAssertEqual(events.last, .exited(.code(0)))
    }

    /// Another paired controller is told the run does not exist, for every run op.
    func testAnotherControllersRunIsUnknown() async throws {
        let repo = try repo()
        let core = try host()
        let mine = Controller(core: core), theirs = Controller(core: core)
        _ = try await mine.hello()
        _ = try await theirs.hello()
        let ref = try await sync(repo, over: mine)
        let runID = try await start("sleep 30", ref, over: mine)

        let attach = await remote { try await theirs.request(.runAttach(runID: runID, offset: 0)) }
        let signal = await remote { try await theirs.request(.runSignal(runID: runID, signal: SIGTERM)) }
        let cancel = await remote { try await theirs.request(.runCancel(runID: runID)) }
        let result = await remote { try await self.result(runID, over: theirs) }
        XCTAssertEqual([attach, signal, cancel, result], Array(repeating: "unknown_run", count: 4))

        let cancelled = try await mine.request(.runCancel(runID: runID))
        XCTAssertEqual(cancelled, .runCancel)
        let ended = try await mine.events(runID)
        XCTAssertEqual(ended.last, .exited(.signal(SIGINT)))
    }

    func testOutputEventsCarryAtMost64KiB() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let runID = try await start("head -c 300000 /dev/zero | tr '\\0' a", ref, over: c)
        let events = try await c.events(runID)
        var next: Int64 = 0
        for case .output(_, let offset, let data) in events {
            XCTAssertLessThanOrEqual(data.count, 64 * 1024)
            XCTAssertEqual(offset, next, "contiguous offsets")
            next = offset + Int64(data.count)
        }
        XCTAssertEqual(next, 300_000)
    }

    func testPiecesSplitAtTheWireCap() {
        let data = Data(repeating: 7, count: 150_000)
        let pieces = DelegationHost.pieces(of: data, at: 1000)
        XCTAssertEqual(pieces.map(\.offset), [1000, 1000 + 65536, 1000 + 131072])
        XCTAssertEqual(pieces.map(\.data.count), [65536, 65536, 150_000 - 131072])
        XCTAssertEqual(DelegationHost.pieces(of: Data([1]), at: 9).map(\.offset), [9])
    }

    /// A slow `host.info` (docker wedged) must not hold the connection's serial queue: the
    /// `sync.push` behind it waits on bytes arriving on that same connection.
    func testSlowHostInfoDoesNotBlockSyncPush() async throws {
        let wedged = Once()
        let slow = HostInfoProbe(stateRoot: FileManager.default.temporaryDirectory, hostdVersion: "t") { _, _ in
            // The first tool the probe runs hangs for 3 s; the rest answer at once.
            if wedged.first() { Thread.sleep(forTimeInterval: 3) }
            return nil
        }
        let repo = try repo()
        let c = Controller(core: try host(probe: slow))
        _ = try await c.hello()
        let info = c.post(.hostInfo)
        let started = Date()
        try await sync(repo, over: c)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "sync.push waited behind host.info")
        guard case .hostInfo = try await c.reply(to: info, timeout: 60) else { return XCTFail("host.info reply") }
    }

    /// A run that never ran (here, a snapshot whose tree the host cannot match) ends with the
    /// reason and 125, rather than leaving the controller waiting on an exit that never comes.
    func testARunThatNeverRanEndsWith125AndTheReason() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let wrong = SnapshotRef(repoRoot: ref.repoRoot, wtKey: ref.wtKey, worktreeName: ref.worktreeName,
                                commit: ref.commit, tree: String(repeating: "f", count: 40))
        let runID = try await start("echo must-not-run", wrong, over: c)
        let events = try await c.events(runID)
        XCTAssertFalse(output(events).contains("must-not-run"))
        XCTAssertTrue(output(events).hasPrefix("flightdeck: "), output(events))
        XCTAssertEqual(events.last, .exited(.code(125)))
        let (commit, _) = try await result(runID, over: c)
        XCTAssertNil(commit, "nothing ran, so nothing changed")
    }

    /// A service starts through the services (so they hold its slot and can sync and down
    /// it), and the service ops reach them through the router.
    func testServiceStartsThroughTheServicesAndTheirOpsAreRouted() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        var service = spec("echo up; sleep 30")
        service.service = true
        service.downCommand = "echo down-ran"
        guard case .runStart(let runID) = try await c.request(.runStart(ref: ref, spec: service, owner: "tab", apply: true))
        else { return XCTFail("run.start") }
        try await c.started(runID)
        _ = try await c.request(.screenStatus)

        // service.sync finds the service's own slot only if the services started it.
        let synced = try await c.request(.serviceSync(service: runID, ref: ref))
        XCTAssertEqual(synced, .serviceSync)
        let downed = try await c.request(.serviceDown(service: runID))
        XCTAssertEqual(downed, .serviceDown)
        let events = try await c.events(runID)
        XCTAssertTrue(output(events).contains("down-ran"), output(events))
        XCTAssertEqual(events.last, .exited(.signal(SIGTERM)))
    }

    /// Binary frames from a connection that has not said hello go nowhere; once it closes,
    /// its channels fail rather than wait forever.
    func testMuxLivesFromHelloUntilClose() async throws {
        let c = Controller(core: try host())
        let early = try await c.mux.open()
        try await early.write(Data("before hello".utf8))   // dropped: no mux yet

        _ = try await c.hello()
        let channel = try await c.mux.open()
        let ref = SnapshotRef(repoRoot: String(repeating: "a", count: 40), wtKey: "abcd", worktreeName: "w",
                              commit: String(repeating: "b", count: 40), tree: String(repeating: "c", count: 40))
        let id = c.post(.delegation(.syncPush(ref: ref, channel: channel.id)))
        try await channel.write(Data("partial".utf8))
        try await Task.sleep(nanoseconds: 200_000_000)
        c.closeConnection()
        let code = await remote { try await c.reply(to: id) }
        XCTAssertNotNil(code, "the push in flight fails when its connection's mux shuts down")
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

// MARK: - Final review: stop, revoke, transfer channels

extension DelegationHostTests {
    private struct Parts {
        let core: HostServerCore
        let delegation: DelegationHost
        let runner: Runner
    }

    private func parts(idle: IdleTracker? = nil, transferStall: TimeInterval = DelegationHost.transferStall) throws -> Parts {
        let root = try tempDir("fd-host")
        let workspace = Workspace(root: root)
        let screen = ScreenLease()
        let runner = Runner(runsRoot: root.appendingPathComponent("runs"), shell: "/bin/sh",
                            hostEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSTemporaryDirectory()],
                            power: NoPowerAssertions(), console: UnsupportedConsoleSession(), screen: screen,
                            lifecycle: .workspace(workspace))
        let delegation = DelegationHost(runner: runner, workspace: workspace, screen: screen,
                                        portCheck: PortCheck(run: { _, _ in nil }), screenSupported: false, idle: idle,
                                        transferStall: transferStall)
        let core = HostServerCore(hostName: { "mini" }, probe: HostInfoProbe(stateRoot: root, hostdVersion: "t") { _, _ in nil },
                                  delegation: delegation)
        return Parts(core: core, delegation: delegation, runner: runner)
    }

    private func service(_ command: String, down: String) -> RunSpec {
        var s = spec(command)
        s.service = true
        s.downCommand = down
        return s
    }

    private func startService(_ spec: RunSpec, _ ref: SnapshotRef, over c: Controller) async throws -> String {
        guard case .runStart(let runID) = try await c.request(.runStart(ref: ref, spec: spec, owner: "tab", apply: true)) else {
            throw CocoaError(.featureUnsupported)
        }
        return runID
    }

    private func waitTerminal(_ runner: Runner, _ ids: [String], within seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ids.allSatisfy({ runner.phase(runID: $0).map { $0 != .running && !$0.isQueued } ?? true }) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("still live after \(seconds)s: \(ids.map { runner.phase(runID: $0).map { "\($0)" } ?? "gone" })")
    }

    /// Revoking a controller used to close its connections and nothing else: its runs kept
    /// running and its services kept their ports for the whole orphan timeout, for a key the
    /// user had just said they no longer trust.
    func testRevokeCancelsTheSlotsRunsAndDownsItsServicesAtOnce() async throws {
        let repo = try repo()
        let p = try parts()
        let c = Controller(core: p.core), other = Controller(core: p.core)
        _ = try await c.hello()
        _ = try await other.hello()
        let ref = try await sync(repo, over: c)
        let otherRef = try await sync(repo, over: other)
        let marker = try tempDir("down").appendingPathComponent("down-ran")

        let run = try await start("echo ready; while :; do sleep 0.1; done", ref, over: c)
        let svc = try await startService(service("echo up; while :; do sleep 0.1; done", down: "touch '\(marker.path)'"), ref, over: c)
        let bystander = try await start("echo ready; while :; do sleep 0.1; done", otherRef, over: other)
        try await c.started(run)
        try await c.started(svc)
        try await other.started(bystander)

        p.core.disconnect(slot: c.slot)
        try await waitTerminal(p.runner, [run, svc], within: 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the revoked controller's service was downed")
        XCTAssertEqual(p.runner.phase(runID: bystander), .running, "another controller's work is not touched")
        await p.delegation.shutdown(grace: 0.2, deadline: 5)
    }

    /// A `run.start` already being routed when the revoke lands (its exec probe or checkout
    /// was awaiting) must not start a run for the revoked key afterwards.
    func testRunStartForARevokedSlotIsRefused() async throws {
        let repo = try repo()
        let p = try parts()
        let c = Controller(core: p.core)
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        // The router hears the revoke; the connection, as seen by the router, is still there.
        p.delegation.revoked(c.slot)
        let refused = await remote { try await self.start("echo never", ref, over: c) }
        XCTAssertNotNil(refused)
        XCTAssertEqual(p.runner.liveRuns(controller: c.slot), [])
    }

    /// The hostd's SIGTERM path: services downed with their `down` command, runs ended, all
    /// within launchd's ExitTimeOut.
    func testShutdownDownsServicesAndEndsRuns() async throws {
        let repo = try repo()
        let p = try parts()
        let c = Controller(core: p.core)
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let marker = try tempDir("down").appendingPathComponent("down-ran")
        let run = try await start("trap '' TERM INT; echo ready; while :; do sleep 0.1; done", ref, over: c)
        let svc = try await startService(service("echo up; while :; do sleep 0.1; done", down: "touch '\(marker.path)'"), ref, over: c)
        try await c.started(run)
        try await c.started(svc)

        let began = Date()
        await p.delegation.shutdown(grace: 0.5, deadline: 10)
        XCTAssertLessThan(Date().timeIntervalSince(began), 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(p.runner.phase(runID: run), .exited(.signal(SIGKILL)))
        XCTAssertEqual(p.runner.phase(runID: svc).map { if case .died = $0 { return true }; return false }, false)
    }

    /// The host read a pushed bundle to EOF but never sent its own, so the channel stayed
    /// half-open on both ends, and a mux entry per push lived as long as the connection.
    func testSyncPushRetiresItsChannel() async throws {
        let repo = try repo()
        let c = Controller(core: try host())
        _ = try await c.hello()
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        let bundle = try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: [])
        defer { try? FileManager.default.removeItem(at: bundle) }
        let channel = try await c.mux.open()
        let id = c.post(.delegation(.syncPush(ref: ref, channel: channel.id)))
        try await channel.write(try Data(contentsOf: bundle))
        await channel.finish()
        let pushed = try await c.reply(to: id)
        XCTAssertEqual(pushed, .delegation(.syncPush))

        // Polled rather than awaited: on a host that never finishes, the read never returns.
        let sawEOF = EOFFlag()
        Task { if (try? await channel.read()) == .some(nil) { sawEOF.set() } }
        let deadline = Date().addingTimeInterval(5)
        while !sawEOF.isSet && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(sawEOF.isSet, "the host finishes its side once it has the whole bundle")
    }
}

// MARK: - Idle tracking

extension DelegationHostTests {
    private func eventually(_ what: String, within seconds: TimeInterval = 30,
                            _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("never: \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A run belongs to the host, not to the connection that started it: a controller that
    /// closes its lid mid-build must not make the box look idle (and get it stopped) while the
    /// build is still going, and the run's end must still be heard with nobody attached.
    func testARunKeepsTheHostBusyAfterItsControllerLeavesUntilItEnds() async throws {
        let repo = try repo()
        let idle = IdleTracker()
        let p = try parts(idle: idle)
        let c = Controller(core: p.core)
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let run = try await start("echo ready; while :; do sleep 0.1; done", ref, over: c)
        try await c.started(run)
        c.closeConnection()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(idle.idleSince, "a live run with no controller attached is still activity")

        p.runner.cancel(runID: run)
        try await waitTerminal(p.runner, [run], within: 20)
        try await eventually("idle after the run ended") { idle.idleSince != nil }
    }

    /// A run that never ran (its checkout failed) ends without an exit of its own; it must
    /// still close its activity, or the host would never look idle again.
    func testARunThatFailedBeforeRunningDoesNotKeepTheHostBusy() async throws {
        let repo = try repo()
        let idle = IdleTracker()
        let p = try parts(idle: idle)
        let c = Controller(core: p.core)
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let wrong = SnapshotRef(repoRoot: ref.repoRoot, wtKey: ref.wtKey, worktreeName: ref.worktreeName,
                                commit: ref.commit, tree: String(repeating: "f", count: 40))
        let runID = try await start("echo must-not-run", wrong, over: c)
        let events = try await c.events(runID)
        XCTAssertEqual(events.last, .exited(.code(125)))
        try await eventually("idle after the failed run") { idle.idleSince != nil }
    }

    /// A `sync.push` is activity while its bundle streams in, and ends as activity when its
    /// connection drops mid-transfer: the aborted push must not leave the host busy forever.
    func testAnAbortedSyncPushIsActivityUntilItFails() async throws {
        let idle = IdleTracker()
        let p = try parts(idle: idle)
        let c = Controller(core: p.core)
        _ = try await c.hello()
        let channel = try await c.mux.open()
        let ref = SnapshotRef(repoRoot: String(repeating: "a", count: 40), wtKey: "abcd", worktreeName: "w",
                              commit: String(repeating: "b", count: 40), tree: String(repeating: "c", count: 40))
        let id = c.post(.delegation(.syncPush(ref: ref, channel: channel.id)))
        try await channel.write(Data("partial".utf8))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(idle.idleSince, "a push in flight is activity")

        c.closeConnection()
        let code = await remote { try await c.reply(to: id) }
        XCTAssertNotNil(code)
        try await eventually("idle after the aborted push") { idle.idleSince != nil }
    }

    /// A controller that went silent mid-push with its connection still up (a frozen peer, or
    /// a sleeping laptop whose half-open TCP the host has not yet noticed) must not hold the
    /// host busy forever: a transfer that makes no progress for the stall deadline fails.
    func testASilentSyncPushFailsAfterTheStallDeadlineAndTheHostGoesIdle() async throws {
        let idle = IdleTracker()
        let p = try parts(idle: idle, transferStall: 0.3)
        let c = Controller(core: p.core)
        _ = try await c.hello()
        let channel = try await c.mux.open()
        let ref = SnapshotRef(repoRoot: String(repeating: "a", count: 40), wtKey: "abcd", worktreeName: "w",
                              commit: String(repeating: "b", count: 40), tree: String(repeating: "c", count: 40))
        let id = c.post(.delegation(.syncPush(ref: ref, channel: channel.id)))
        try await channel.write(Data("partial".utf8))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(idle.idleSince, "a push in flight is activity")

        let code = await remote { try await c.reply(to: id, timeout: 10) }
        XCTAssertEqual(code, "transfer_stalled")
        try await eventually("idle after the stalled push") { idle.idleSince != nil }
    }

    /// A transfer that keeps making progress is never cut, however long it takes in all.
    func testASlowButSteadySyncPushIsNotCut() async throws {
        let repo = try repo()
        let p = try parts(transferStall: 0.5)
        let c = Controller(core: p.core)
        _ = try await c.hello()
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        let bundle = try Data(contentsOf: try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: []))
        let channel = try await c.mux.open()
        let id = c.post(.delegation(.syncPush(ref: ref, channel: channel.id)))
        let pieces = stride(from: 0, to: bundle.count, by: max(1, bundle.count / 4)).map {
            bundle.subdata(in: $0..<min($0 + max(1, bundle.count / 4), bundle.count))
        }
        for piece in pieces {
            try await channel.write(piece)
            try await Task.sleep(nanoseconds: 250_000_000)   // 1 s+ in all, past the 0.5 s deadline
        }
        await channel.finish()
        let pushed = try await c.reply(to: id)
        XCTAssertEqual(pushed, .delegation(.syncPush))
    }

    /// A service is activity from its start until it is downed, like a run.
    func testAServiceKeepsTheHostBusyUntilItIsDowned() async throws {
        let repo = try repo()
        let idle = IdleTracker()
        let p = try parts(idle: idle)
        let c = Controller(core: p.core)
        _ = try await c.hello()
        let ref = try await sync(repo, over: c)
        let svc = try await startService(service("echo up; while :; do sleep 0.1; done", down: "true"), ref, over: c)
        try await c.started(svc)
        XCTAssertNil(idle.idleSince, "a live service is activity")

        let downed = try await c.request(.serviceDown(service: svc))
        XCTAssertEqual(downed, .serviceDown)
        try await eventually("idle after the service was downed") { idle.idleSince != nil }
    }
}

private extension RunPhase {
    var isQueued: Bool { if case .queued = self { return true }; return false }
}

private final class EOFFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.withLock { raised = true } }
    var isSet: Bool { lock.withLock { raised } }
}
