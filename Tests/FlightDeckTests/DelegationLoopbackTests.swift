import FleetKit
import Foundation
import HostKit
import Network
import XCTest
@testable import FlightDeck

/// `flightdeck run` end to end, every layer real: the app's `DelegationService` as the
/// factory builds it (live adapters, disk mirror, registry), a TLS `HostLink` from a real
/// `HostService`, and an in-process `DarwinHostServer` whose `DelegationHost` runs real
/// processes in real checkouts of temp git repos.
///
/// The unit suites each fake one side of a seam; this is the only place the two sides are
/// proven to agree. Every bug the C8 merge surfaced (a stale `HostLinking`, a host acking a
/// result the controller had not stored) was invisible to both sides' own tests.
///
/// Hermetic on purpose: the host's `PATH` starts with stub `xcodebuild` and `docker`
/// scripts, so a run never reaches a real toolchain or a real Docker daemon, and the console
/// probe is fixed, so the screen queue does not depend on who is logged in. No app bundle is
/// launched (AGENTS.md rule 2).
@MainActor
final class DelegationLoopbackTests: XCTestCase {
    /// A console with a user logged in and unlocked, so `screen` runs are served without a
    /// real login session.
    private struct ConsoleAvailable: ConsoleSessionProbing {
        func current() -> ConsoleSession { ConsoleSession(supported: true, consoleUser: true, locked: false) }
    }

    private var root: URL!
    private var state: URL!
    private var stubs: URL!
    private var key: FleetDeviceKey!
    private var workspace: Workspace!
    private var runner: Runner!
    private var screen: ScreenLease!
    private var server: DarwinHostServer!
    private var hostService: HostService!
    private var service: DelegationService!
    private let tabA = UUID()
    private let tabB = UUID()

    override func setUp() async throws {
        // Short and under /tmp: the host's admin socket lives in its root, and a sun_path
        // under the per-user temp directory runs past 104 bytes.
        root = URL(fileURLWithPath: "/tmp/fdl-\(UUID().uuidString.prefix(6))")
        state = root.appendingPathComponent("controller", isDirectory: true)
        stubs = root.appendingPathComponent("stub-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try stub("xcodebuild", """
            #!/bin/sh
            echo "stub xcodebuild $*"
            echo "Test Suite 'All tests' passed"
            echo "** TEST SUCCEEDED **"
            """)
        try stub("docker", "#!/bin/sh\nexit 0\n")

        // The host: hostd's own wiring (`DelegationHost.standard`) with the hermetic seams.
        let hostRoot = root.appendingPathComponent("host", isDirectory: true)
        // Runs go through a login shell (`sh -lc`), whose /etc/profile has path_helper put the
        // system directories first again, so the stubs go on PATH the way a host user's own
        // tools do: from the profile in its HOME.
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        try Data("PATH=\"\(stubs.path):$PATH\"; export PATH\n".utf8).write(to: hostRoot.appendingPathComponent(".profile"))
        workspace = Workspace(root: hostRoot)
        screen = ScreenLease()
        runner = Runner(runsRoot: hostRoot.appendingPathComponent("runs"), shell: "/bin/sh",
                        hostEnvironment: ["PATH": "\(stubs.path):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": hostRoot.path],
                        power: NoPowerAssertions(), console: ConsoleAvailable(), screen: screen,
                        lifecycle: .workspace(workspace))
        let delegation = DelegationHost(runner: runner, workspace: workspace, screen: screen,
                                        portCheck: PortCheck(searchPath: [stubs.path]), screenSupported: true)
        let docker = stubs.appendingPathComponent("docker").path
        let probe = HostInfoProbe(stateRoot: hostRoot, hostdVersion: "t") { path, args in
            HostInfoProbe.runCommand(path.hasSuffix("/docker") ? docker : path, args)
        }
        key = FleetDeviceKey.mint()
        try ControllerStore(root: hostRoot).add(.init(slot: key.slot, name: "laptop", secret: key.secret, pairedAt: Date()))
        server = DarwinHostServer(root: hostRoot, port: nil, hostName: { "mini" }, probe: probe, delegation: delegation)
        let port = try await server.start()

        // The controller: a paired host record, a real link, and the service as the app builds it.
        let registry = HostRegistry(fileURL: state.appendingPathComponent("hosts.json"), secrets: InMemoryHostSecretStore())
        _ = try registry.add(key: key, name: "mini", serviceName: "fdl-none-\(UUID().uuidString.prefix(6))",
                             endpoints: ["127.0.0.1:\(port)"])
        hostService = HostService(registry: registry, controllerName: "laptop")
        hostService.start()
        try await waitUntil { if case .online = self.hostService.statuses[self.key.slot] { true } else { false } }
        let titles = [tabA: "alpha", tabB: "beta"]
        service = DelegationServiceFactory.live(hostService: hostService, stateDirectory: state,
                                                sessionTitle: { titles[$0] })
    }

    override func tearDown() async throws {
        hostService?.forget(slot: key.slot)
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private func stub(_ name: String, _ script: String) throws {
        let url = stubs.appendingPathComponent(name)
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    private nonisolated static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        p.currentDirectoryURL = dir
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "GIT_CONFIG_NOSYSTEM": "1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A committed repo with `a.txt` and an ignored `build/`, as a project the CLI runs in.
    private func repo(_ name: String = "proj") throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.git(["init", "-q", "-b", "main"], in: dir)
        try write(".gitignore", "build/\n", in: dir)
        try write("a.txt", "alpha\n", in: dir)
        try Self.git(["add", "-A"], in: dir)
        try Self.git(["commit", "-q", "-m", "init"], in: dir)
        return dir
    }

    private func write(_ path: String, _ text: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: The control socket's side

    private final class Frames {
        var all: [ServerFrame] = []
        var started: WireDelegateStarted? {
            for case .delegateStarted(_, let s) in all { return s }
            return nil
        }
        var exit: Int32? {
            for case .delegateExit(_, let status) in all { return status }
            return nil
        }
        var error: (code: String, message: String?)? {
            for case .err(_, let code, let message) in all { return (code, message) }
            return nil
        }
        func output(_ stream: String? = nil) -> String {
            all.reduce(into: "") {
                if case .delegateOutput(_, let s, _, let data) = $1, stream == nil || s == stream {
                    $0 += String(decoding: data, as: UTF8.self)
                }
            }
        }
        var notices: [String] { all.compactMap { if case .delegateNotice(_, let m) = $0 { return m }; return nil } }
        var isDone: Bool {
            all.contains {
                switch $0 {
                case .delegateExit, .err, .ack, .delegatePatch, .delegateApplied: return true
                default: return false
                }
            }
        }
    }

    private func send(_ request: DelegateRequest, as tab: UUID? = nil) -> Frames {
        let frames = Frames()
        service.handle(request, caller: tab.map(ControlCaller.session) ?? .human, cid: 1) { frames.all.append($0) }
        return frames
    }

    private func done(_ frames: Frames, timeout: TimeInterval = 60) async throws {
        try await waitUntil(timeout: timeout) { frames.isDone }
    }

    private func run(_ command: String, in repo: URL, as tab: UUID? = nil, fetch: [String] = [],
                     include: [String] = [], screen: Bool = false) async throws -> Frames {
        let frames = send(.run(WireDelegateRun(cwd: repo.path, host: "mini", command: [command], include: include,
                                               fetch: fetch, screen: screen)), as: tab)
        try await done(frames)
        return frames
    }

    /// Offsets are the run's own byte offsets: each chunk starts where the last one ended.
    private func assertContiguous(_ frames: Frames, file: StaticString = #filePath, line: UInt = #line) {
        var next: Int64 = 0
        for case .delegateOutput(_, _, let offset, let data) in frames.all {
            XCTAssertEqual(offset, next, "a gap or a repeat in the output", file: file, line: line)
            next = offset + Int64(data.count)
        }
    }

    // MARK: -

    /// Sync (uncommitted edits included), run, streamed output, and the run's own exit status,
    /// a signal mapped to 128+n.
    func testRunEndToEnd() async throws {
        let repo = try repo()
        try write("a.txt", "edited but not committed\n", in: repo)

        let built = try await run("cat a.txt && xcodebuild test -scheme App", in: repo, as: tabA)
        XCTAssertNil(built.error.map { "\($0)" })
        XCTAssertEqual(built.started?.host, "mini")
        XCTAssertEqual(built.output("stdout"), """
            edited but not committed
            stub xcodebuild test -scheme App
            Test Suite 'All tests' passed
            ** TEST SUCCEEDED **

            """)
        XCTAssertEqual(built.exit, 0)
        assertContiguous(built)

        let failed = try await run("echo to-out; echo to-err >&2; exit 3", in: repo, as: tabA)
        XCTAssertEqual(failed.output("stdout"), "to-out\n")
        XCTAssertEqual(failed.output("stderr"), "to-err\n")
        XCTAssertEqual(failed.exit, 3)

        let killed = try await run("kill -TERM $$", in: repo, as: tabA)
        XCTAssertEqual(killed.exit, 128 + SIGTERM)
    }

    /// The run's edits come back as a patch, are applied on request, and the host's copy is
    /// dropped only by the controller's `run.ack` after it stored the bundle (ruling 24).
    func testResultPatchComesBackAndIsAcked() async throws {
        let repo = try repo()
        let frames = try await run("echo edited > a.txt", in: repo, as: tabA)
        XCTAssertEqual(frames.exit, 0)
        let id = try XCTUnwrap(frames.started?.runID)
        try await waitUntil { self.service.registry.run(id)?.resultCommit != nil }
        let record = try XCTUnwrap(service.registry.run(id))
        XCTAssertEqual(read("a.txt", in: repo), "alpha\n", "review mode writes nothing until apply")

        // Acked: the host has dropped its copy.
        let repoRoot = try XCTUnwrap(record.snapshot?.repoRoot)
        var dropped = false
        for _ in 0..<100 where !dropped {
            do {
                let copy = try await workspace.resultBundle(controller: key.slot, repoRoot: repoRoot, runID: record.hostRunID)
                copy.map { try? FileManager.default.removeItem(at: $0) }
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch SyncError.resultExpired {
                dropped = true
            }
        }
        XCTAssertTrue(dropped, "the host still holds a result the controller stored")

        let diff = send(.diff(run: id), as: tabA)
        try await done(diff)
        guard case .delegatePatch(_, let patch)? = diff.all.last else { return XCTFail("\(diff.all)") }
        XCTAssertTrue(patch.patch?.contains("-alpha\n+edited") == true, patch.patch ?? "nil")

        let applied = send(.apply(run: id), as: tabA)
        try await done(applied)
        XCTAssertEqual(applied.all.last, .delegateApplied(cid: 1, WireDelegateApplied(runID: id, conflicts: [])))
        XCTAssertEqual(read("a.txt", in: repo), "edited\n")
    }

    /// `--fetch` globs come back into the local worktree, under its ignored build output.
    func testArtifactsComeBack() async throws {
        let repo = try repo()
        let frames = try await run("mkdir -p build/logs && echo report > build/logs/report.txt && echo other > build/x.txt",
                                   in: repo, as: tabA, fetch: ["build/logs/*.txt"])
        XCTAssertEqual(frames.exit, 0)
        try await waitUntil { self.read("build/logs/report.txt", in: repo) == "report\n" }
        XCTAssertNil(read("build/x.txt", in: repo), "only what the globs matched")
    }

    /// `up --port auto:R`: a service on the host's R answers on a local port the app bound.
    func testServiceForwardsPort() async throws {
        let repo = try repo()
        let remote = try Self.freePort()
        let echo = """
            exec perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", \
            LocalPort => \(remote), Listen => 5, ReuseAddr => 1) or die "bind: $!"; \
            while ($c = $s->accept) { while (sysread($c, $b, 4096)) { syswrite($c, $b) } close $c }'
            """
        let up = send(.up(WireDelegateRun(cwd: repo.path, host: "mini", command: [echo], ports: ["auto:\(remote)"])),
                      as: tabA)
        try await waitUntil(timeout: 30) { up.started != nil || up.error != nil }
        let started = try XCTUnwrap(up.started, "\(up.all)")
        let forward = try XCTUnwrap(started.ports.first)
        XCTAssertEqual(forward.remote, remote)
        XCTAssertNotEqual(forward.local, 0)

        // The service binds after it starts; until then the host answers `dial_failed` and
        // the local connection simply closes.
        var reply: Data?
        let deadline = Date().addingTimeInterval(20)
        while reply != Data("ping through the forward\n".utf8), Date() < deadline {
            reply = await Self.echo(port: forward.local, Data("ping through the forward\n".utf8))
            if reply?.isEmpty != false { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        XCTAssertEqual(reply.map { String(decoding: $0, as: UTF8.self) }, "ping through the forward\n")

        let down = send(.down(service: started.runID, cwd: repo.path), as: tabA)
        try await done(down)
        XCTAssertEqual(down.all.last, .ack(cid: 1))
    }

    /// The controller's link drops mid-run: the run carries on on the host, and the stream
    /// resumes from the disk copy's offset with no gap and no duplicate.
    func testRunSurvivesControllerDrop() async throws {
        let repo = try repo()
        let frames = send(.run(WireDelegateRun(cwd: repo.path, host: "mini",
                                               command: ["for i in $(seq 1 30); do echo line$i; sleep 0.1; done"])),
                          as: tabA)
        try await waitUntil(timeout: 30) { frames.output().contains("line5\n") }
        let link = try XCTUnwrap(hostService.link(slot: key.slot))
        link.stop()
        try await waitUntil { if case .online = self.hostService.statuses[self.key.slot] { false } else { true } }
        let missed = frames.output()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(frames.output(), missed, "nothing arrives while the link is down")
        link.start()

        try await done(frames)
        XCTAssertEqual(frames.exit, 0, "\(frames.all.suffix(3))")
        XCTAssertEqual(frames.output(), (1...30).map { "line\($0)\n" }.joined())
        assertContiguous(frames)
    }

    /// Two tabs want the host's one screen: the second is told who holds it, by this Mac's
    /// run id and the holder tab's title, and runs once the first lets go.
    func testScreenQueueAcrossTwoSessions() async throws {
        let repo = try repo()
        let first = send(.run(WireDelegateRun(cwd: repo.path, host: "mini", command: ["sleep 1.5; echo first"],
                                              screen: true)), as: tabA)
        try await waitUntil(timeout: 30) { self.screen.holder != nil }
        let firstID = try XCTUnwrap(first.started?.runID)

        let second = try await run("echo second", in: repo, as: tabB, screen: true)
        try await done(first)
        XCTAssertEqual(first.exit, 0)
        XCTAssertEqual(second.exit, 0)
        XCTAssertEqual(second.output(), "second\n")
        XCTAssertTrue(second.notices.contains("waiting for mini's screen — held by \(firstID) (session \"alpha\")"),
                      "\(second.notices)")
        XCTAssertNil(screen.holder)
    }

    /// A preflight failure (§7) ends before step 8: no sync, no checkout, no run on the host.
    func testPreflightFailureTouchesNothingRemote() async throws {
        let repo = try repo()
        let missing = try await run("true", in: repo, as: tabA, include: ["secrets.env"])
        XCTAssertNotNil(missing.error, "\(missing.all)")

        // A held remote port is found by asking the host, and still starts nothing there.
        let remote = try Self.freePort()
        let holder = try Self.listen(on: remote)
        defer { close(holder) }
        let held = send(.run(WireDelegateRun(cwd: repo.path, host: "mini", command: ["true"], ports: ["auto:\(remote)"])),
                        as: tabA)
        try await done(held)
        XCTAssertEqual(held.error?.code, "port_held", "\(held.all)")

        XCTAssertTrue(service.registry.runs.isEmpty)
        XCTAssertNil(runner.owner(runID: "r1"), "the host started nothing")
        let usage = try await workspace.usage(controller: key.slot)
        XCTAssertEqual(usage, [], "the host checked nothing out")
    }

    /// `exec` runs in the host's existing checkout without syncing: before any run it is
    /// refused, after one it sees that run's leftovers and not the local edits made since.
    func testExecWithoutSync() async throws {
        let repo = try repo()
        let early = send(.exec(WireDelegateRun(cwd: repo.path, host: "mini", command: ["true"])), as: tabA)
        try await done(early)
        XCTAssertEqual(early.error?.code, "no_checkout", "\(early.all)")

        let synced = try await run("mkdir -p build && echo kept > build/state.txt", in: repo, as: tabA)
        XCTAssertEqual(synced.exit, 0)
        try write("a.txt", "changed locally since\n", in: repo)

        let exec = send(.exec(WireDelegateRun(cwd: repo.path, host: "mini", command: ["cat a.txt build/state.txt"])),
                        as: tabA)
        try await done(exec)
        XCTAssertEqual(exec.exit, 0, "\(exec.all)")
        XCTAssertEqual(exec.output(), "alpha\nkept\n")
    }

    // MARK: Sockets

    /// A port nothing listens on right now.
    private nonisolated static func freePort() throws -> UInt16 {
        let fd = try listen(on: 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    private nonisolated static func listen(on port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 5) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        return fd
    }

    /// Connects to 127.0.0.1:`port`, writes `payload`, half-closes, and reads to EOF. Nil when
    /// the connection is refused; empty when it closed without an answer.
    private nonisolated static func echo(port: UInt16, _ payload: Data) async -> Data? {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var nosigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return nil }
            _ = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            shutdown(fd, SHUT_WR)
            var answer = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(fd, &buffer, buffer.count)
                guard n > 0 else { break }
                answer.append(contentsOf: buffer[0..<n])
            }
            return answer
        }.value
    }
}
