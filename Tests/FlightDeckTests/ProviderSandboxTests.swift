import Darwin
import HostKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// `ProviderSandbox` against the real `/usr/bin/sandbox-exec`. These spawn processes but open no
/// windows. Every folder is a fresh temp folder.
final class ProviderSandboxTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderSandboxTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
                          "this Mac has no sandbox-exec")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Fixtures

    /// A user provider (trusted without approval) whose generator is `command`.
    private func provider(_ command: [String], timeout: Int = 30, network: Bool = false,
                          source: ProviderSource = .user, files: [(String, String)] = []) throws -> ResolvedProvider {
        let folder = tmp.appendingPathComponent("provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("id = \"t\"\n".utf8).write(to: folder.appendingPathComponent("provider.toml"))
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let generator = ProviderGenerator(command: command, timeout: HostKit.Duration(seconds: timeout), network: network)
        let manifest = ProviderManifest(id: "t", name: "T", version: "1", contract: 1, kinds: [], generator: generator)
        let trust: ProviderTrustState = source == .bundled ? .bundled : .user
        return ResolvedProvider(id: "t", manifest: manifest, source: source, folder: folder,
                                trust: trust, problems: [], digest: nil)
    }

    private func sandbox(sandboxExec: String = "/usr/bin/sandbox-exec",
                         runner: any CommandRunner = SystemCommandRunner()) -> ProviderSandbox {
        ProviderSandbox(sandboxExecPath: sandboxExec, runner: runner,
                        snapshotRoot: tmp.appendingPathComponent("runs"), killGrace: 0.5)
    }

    private func output() throws -> URL {
        let url = tmp.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exited(_ result: ProviderSandboxResult, file: StaticString = #filePath, line: UInt = #line)
        -> (code: Int32, stderr: String) {
        guard case .exited(let code, _, let stderr, _) = result else {
            XCTFail("expected an exit, got \(result)", file: file, line: line)
            return (-1, "")
        }
        return (code, stderr)
    }

    /// A TCP listener on loopback that never accepts. The kernel still completes the handshake
    /// into the backlog, so `nc -z` succeeds against it exactly when the network is reachable;
    /// that makes the "blocked" result mean the sandbox, not an offline Mac.
    private func loopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 8), 0)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    // MARK: - Network

    func testLoopbackConnectIsBlockedThoughItWorksUnsandboxed() async throws {
        let (fd, port) = try loopbackListener()
        defer { close(fd) }
        let nc = ["/usr/bin/nc", "-z", "-G", "2", "127.0.0.1", "\(port)"]

        // The control: the same probe outside the sandbox reaches the listener.
        let control = try await SystemCommandRunner().run(
            executable: nc[0], arguments: Array(nc.dropFirst()), cwd: tmp, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(control.exitCode, 0, "control probe failed: \(control.stderr)")

        let result = try await sandbox().run(try provider(nc), outputDirectory: try output())
        XCTAssertNotEqual(exited(result).code, 0)
    }

    func testCurlToAnyHostFails() async throws {
        let result = try await sandbox().run(
            try provider(["/usr/bin/curl", "-sS", "--max-time", "5", "http://1.1.1.1/"]),
            outputDirectory: try output())
        let (code, stderr) = exited(result)
        XCTAssertNotEqual(code, 0)
        // 7 is "couldn't connect"; 6 is "couldn't resolve". Either way, no bytes left the Mac.
        XCTAssertFalse(stderr.isEmpty)
    }

    func testNetworkGeneratorIsRefused() async throws {
        let runner = SpawnCountingRunner()
        do {
            _ = try await sandbox(runner: runner).run(try provider(["/usr/bin/true"], network: true),
                                                      outputDirectory: try output())
            XCTFail("expected networkNotAllowed")
        } catch {
            XCTAssertEqual(error as? ProviderSandboxError, .networkNotAllowed)
        }
        XCTAssertEqual(runner.calls, 0)
    }

    // MARK: - Writes

    func testWriteInsideTheOutputFolderSucceedsAndIsDelivered() async throws {
        let out = try output()
        let result = try await sandbox().run(
            try provider(["/bin/sh", "-c", "mkdir -p \"$1/sub\" && echo hi > \"$1/sub/x.txt\" && echo t > \"$TMPDIR/t\"",
                          "sh", "{out}"]),
            outputDirectory: out)
        guard case .exited(let code, _, let stderr, let outputs) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(code, 0, stderr)
        XCTAssertEqual(outputs, ["sub/x.txt"])
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("sub/x.txt"), encoding: .utf8), "hi\n")
    }

    func testWriteOutsideTheOutputFolderFails() async throws {
        let outside = tmp.appendingPathComponent("outside.txt")
        let result = try await sandbox().run(
            try provider(["/bin/sh", "-c", "echo pwned > \"$1\"", "sh", outside.path]),
            outputDirectory: try output())
        let (code, stderr) = exited(result)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(stderr.contains("Operation not permitted"), stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    /// The working directory is the checked copy, and the copy is read-only to the generator:
    /// it cannot rewrite itself, or the original it was copied from.
    func testGeneratorCannotWriteIntoItsOwnFolderOrTheOriginal() async throws {
        let p = try provider(["/bin/sh", "-c", "echo x > ./planted; echo y > \"$1/planted\"", "sh", "PLACEHOLDER"])
        var patched = p
        patched.manifest?.generator?.command[4] = p.folder.path
        let result = try await sandbox().run(patched, outputDirectory: try output())
        XCTAssertNotEqual(exited(result).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.folder.appendingPathComponent("planted").path))
    }

    func testEnvironmentIsMinimal() async throws {
        let result = try await sandbox().run(try provider(["/usr/bin/env"]), outputDirectory: try output())
        guard case .exited(0, let stdout, _, _) = result else { return XCTFail("\(result)") }
        let keys = Set(String(decoding: stdout, as: UTF8.self).split(separator: "\n").compactMap {
            $0.split(separator: "=", maxSplits: 1).first.map(String.init)
        })
        XCTAssertEqual(keys, ["PATH", "HOME", "TMPDIR"])
    }

    /// The sandbox checks paths when a file is opened. A descriptor that was already open in
    /// the app is checked by nothing, so the generator must not get one.
    func testInheritedDescriptorIsClosed() async throws {
        let file = tmp.appendingPathComponent("leak.txt")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThan(fd, 2)
        defer { close(fd) }
        let perl = "open(my $f, '>&=', \(fd)) or die \"fd: $!\\n\"; print $f \"leak\\n\" or die \"w: $!\\n\"; close $f or die \"c: $!\\n\""
        let result = try await sandbox().run(try provider(["/usr/bin/perl", "-e", perl]), outputDirectory: try output())
        let (code, stderr) = exited(result)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(stderr.contains("Bad file descriptor"), stderr)
        XCTAssertEqual(try Data(contentsOf: file).count, 0, "the generator wrote through an inherited descriptor")
    }

    // MARK: - Clock

    func testHangingGeneratorIsKilledWithItsChildAtTheTimeout() async throws {
        let pgid = SandboxPIDBox()
        let start = Date()
        let result = try await sandbox().run(
            try provider(["/bin/sh", "-c", "sleep 300 & wait"], timeout: 1),
            outputDirectory: try output(), onSpawn: { pgid.set($0) })
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(elapsed, 10)
        let group = try XCTUnwrap(pgid.value)
        XCTAssertEqual(killpg(group, 0), -1, "the generator's process group outlived the run")
        XCTAssertEqual(errno, ESRCH)
    }

    /// SIGTERM is ignored by the shell and, inherited, by its child: only the SIGKILL that
    /// follows the grace period can end it.
    func testGeneratorIgnoringSigtermIsKilledAfterTheGrace() async throws {
        let pgid = SandboxPIDBox()
        let start = Date()
        let result = try await sandbox().run(
            try provider(["/bin/sh", "-c", "trap '' TERM; sleep 300 & wait"], timeout: 1),
            outputDirectory: try output(), onSpawn: { pgid.set($0) })
        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(killpg(try XCTUnwrap(pgid.value), 0), -1)
    }

    // MARK: - Refusals

    func testMissingSandboxExecIsRefusedAndNothingRuns() async throws {
        let runner = SpawnCountingRunner()
        do {
            _ = try await sandbox(sandboxExec: tmp.appendingPathComponent("no-sandbox-exec").path, runner: runner)
                .run(try provider(["/usr/bin/true"]), outputDirectory: try output())
            XCTFail("expected sandboxUnavailable")
        } catch {
            guard case .sandboxUnavailable? = error as? ProviderSandboxError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(runner.calls, 0)
    }

    func testUnapprovedRepoProviderIsRefused() async throws {
        var p = try provider(["/usr/bin/true"])
        p.source = .repo
        p.trust = .repoNeedsApproval
        let runner = SpawnCountingRunner()
        do {
            _ = try await sandbox(runner: runner).run(p, outputDirectory: try output())
            XCTFail("expected notTrusted")
        } catch {
            XCTAssertEqual(error as? ProviderSandboxError, .notTrusted(.repoNeedsApproval))
        }
        XCTAssertEqual(runner.calls, 0)
    }

    /// The approval covers one exact folder. A change after it (here: after resolution found the
    /// approval) makes the snapshot's digest differ, and the run stops before anything executes.
    func testFolderChangedAfterApprovalIsRefusedBeforeAnythingRuns() async throws {
        let repo = tmp.appendingPathComponent("repo")
        let folder = repo.appendingPathComponent(ProviderRegistry.repoSubpath).appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            id = "acme.p"
            name = "P"
            version = "1.0.0"
            contract = 1

            [[kind]]
            id = "diagram.x"
            summary = "x"
            output = "svg"
            entry = "x.svg"
            instructions = "x.md"

            [generator]
            command = ["./gen.sh"]
            """.utf8).write(to: folder.appendingPathComponent("provider.toml"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("x.md"))
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: folder.appendingPathComponent("gen.sh"))

        let store = ProviderTrustStore(directory: tmp.appendingPathComponent("trust"))
        let registry = ProviderRegistry(userRoot: nil, bundledRoot: nil, trustStore: store)
        let shown = try XCTUnwrap(registry.resolve(repo: repo).first)
        try registry.approve(shown, shownDigest: try XCTUnwrap(shown.digest), repo: repo)
        let approved = try XCTUnwrap(registry.resolve(repo: repo).first)
        XCTAssertEqual(approved.trust, .repoApproved)

        try Data("#!/bin/sh\ncurl evil\n".utf8).write(to: folder.appendingPathComponent("gen.sh"))

        let runner = SpawnCountingRunner()
        do {
            _ = try await sandbox(runner: runner).run(approved, outputDirectory: try output())
            XCTFail("expected providerChanged")
        } catch {
            guard case .providerChanged(let expected, _)? = error as? ProviderSandboxError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(expected, approved.digest)
        }
        XCTAssertEqual(runner.calls, 0)
        // The snapshot is gone even on a refusal.
        let runs = (try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("runs").path)) ?? []
        XCTAssertEqual(runs, [])
    }

    func testApprovedRepoProviderRunsFromTheCopy() async throws {
        var p = try provider(["./gen.sh", "{out}"], files: [("gen.sh", "#!/bin/sh\npwd > \"$1/cwd\"\n")])
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: p.folder.appendingPathComponent("gen.sh").path)
        p.manifest?.generator?.command[0] = "gen.sh"
        p.source = .repo
        p.trust = .repoApproved
        p.digest = try ProviderTrust.digest(folder: p.folder)
        let out = try output()
        let result = try await sandbox().run(p, outputDirectory: out)
        XCTAssertEqual(exited(result).code, 0, exited(result).stderr)
        let cwd = try String(contentsOf: out.appendingPathComponent("cwd"), encoding: .utf8)
        XCTAssertFalse(cwd.contains(p.folder.lastPathComponent), "ran from the original, not the copy: \(cwd)")
        XCTAssertTrue(cwd.contains(tmp.appendingPathComponent("runs").lastPathComponent), cwd)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("runs").path)) ?? [], [])
    }

    func testSymlinkInOutputIsRefused() async throws {
        let out = try output()
        do {
            _ = try await sandbox().run(
                try provider(["/bin/sh", "-c", "ln -s /etc/passwd \"$1/leak\"", "sh", "{out}"]),
                outputDirectory: out)
            XCTFail("a link in the output must not be delivered")
        } catch {
            XCTAssertEqual(error as? ProviderSandboxError, .outputNotRegularFile("leak"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("leak").path))
    }
}

private final class SandboxPIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    func set(_ value: Int32) { lock.lock(); pid = value; lock.unlock() }
    var value: Int32? { lock.lock(); defer { lock.unlock() }; return pid }
}

/// Counts runs and runs nothing: proof that a refusal happened before the spawn.
private final class SpawnCountingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        lock.lock(); count += 1; lock.unlock()
        return CommandResult(stdout: Data(), stderr: "", exitCode: 0)
    }
}
