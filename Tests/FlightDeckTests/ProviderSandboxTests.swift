import AppKit
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
                         runner: any CommandRunner = SystemCommandRunner(),
                         limits: ProviderSandbox.Limits = .standard) -> ProviderSandbox {
        ProviderSandbox(sandboxExecPath: sandboxExec, runner: runner,
                        snapshotRoot: tmp.appendingPathComponent("runs"), killGrace: 0.5, limits: limits)
    }

    private static let small = ProviderSandbox.Limits(stdout: 1 << 20, output: 1 << 20, temp: 1 << 20, file: 64 << 20)

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
        XCTAssertEqual(keys, ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME"])
        // Homebrew's prefixes too, after the system's, so `#!/usr/bin/env node` finds node.
        XCTAssertTrue(String(decoding: stdout, as: UTF8.self)
            .contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin\n"))
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

    // MARK: - Containment beyond files and network

    /// The user's real home folder, resolved, as the sandbox sees it.
    private var realHome: URL {
        URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir)).resolvingSymlinksInPath()
    }

    /// `open` hands an app to LaunchServices, which launches it OUTSIDE the sandbox: the
    /// reviewer's probe app wrote anywhere and reached the network. The control proves the probe
    /// launches when nothing stands in the way, so "it did not launch" means the sandbox.
    func testOpenCannotLaunchAnApp() async throws {
        let app = tmp.appendingPathComponent("Probe.app")
        let marker = tmp.appendingPathComponent("launched")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
                                    "CFBundleIdentifier": "dev.flightdeck.tests.probe-\(UUID().uuidString)",
                                    "LSBackgroundOnly": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let script = macOS.appendingPathComponent("probe")
        try Data("#!/bin/sh\necho launched > '\(marker.path)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { Self.unregister(app) }

        let control = try await SystemCommandRunner().run(
            executable: "/usr/bin/open", arguments: ["-g", "-j", "-n", app.path], cwd: tmp, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(control.exitCode, 0, control.stderr)
        let launched = try await Self.appears(marker, within: 10)
        XCTAssertTrue(launched, "the probe app never launched, so the test proves nothing")
        try FileManager.default.removeItem(at: marker)

        let result = try await sandbox().run(try provider(["/usr/bin/open", "-g", "-j", "-n", app.path]),
                                             outputDirectory: try output())
        XCTAssertNotEqual(exited(result).code, 0)
        let escaped = try await Self.appears(marker, within: 3)
        XCTAssertFalse(escaped, "open launched an app from inside the sandbox")
    }

    func testHomeIsUnreadable() async throws {
        let secret = "secret-\(UUID().uuidString)"
        let planted = realHome.appendingPathComponent(".fd-sandbox-probe-\(UUID().uuidString)")
        try Data(secret.utf8).write(to: planted)
        defer { try? FileManager.default.removeItem(at: planted) }
        let result = try await sandbox().run(try provider(["/bin/cat", planted.path]), outputDirectory: try output())
        guard case .exited(let code, let stdout, let stderr, _) = result else { return XCTFail("\(result)") }
        XCTAssertNotEqual(code, 0)
        XCTAssertFalse(String(decoding: stdout, as: UTF8.self).contains(secret))
        XCTAssertTrue(stderr.contains("Operation not permitted"), stderr)

        let ssh = realHome.appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: ssh.path) {
            let listing = try await sandbox().run(try provider(["/bin/ls", ssh.path]), outputDirectory: try output())
            XCTAssertNotEqual(exited(listing).code, 0, "~/.ssh is listable from the sandbox")
        }
    }

    /// The one part of home a generator may read is the input folder it is handed.
    func testInputDirectoryInsideHomeIsReadable() async throws {
        let input = realHome.appendingPathComponent(".fd-sandbox-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: input) }
        try Data("source text".utf8).write(to: input.appendingPathComponent("src.txt"))
        let result = try await sandbox().run(try provider(["/bin/cat", "{source}"]), outputDirectory: try output(),
                                             inputDirectory: input,
                                             placeholders: ["source": input.appendingPathComponent("src.txt").path])
        guard case .exited(0, let stdout, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "source text")
    }

    /// The find pasteboard rather than the general one, so the user's clipboard is untouched;
    /// the pasteboard server is reached the same way for both.
    @MainActor
    func testClipboardIsUnreadable() async throws {
        let board = NSPasteboard(name: .find)
        let previous = board.string(forType: .string)
        defer {
            board.clearContents()
            if let previous { board.setString(previous, forType: .string) }
        }
        let secret = "pasteboard-\(UUID().uuidString)"
        board.clearContents()
        board.setString(secret, forType: .string)

        let control = try await SystemCommandRunner().run(
            executable: "/usr/bin/pbpaste", arguments: ["-pboard", "find"], cwd: tmp, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(String(decoding: control.stdout, as: UTF8.self), secret, "the control could not read the pasteboard")

        let result = try await sandbox().run(try provider(["/usr/bin/pbpaste", "-pboard", "find"]),
                                             outputDirectory: try output())
        guard case .exited(_, let stdout, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(String(decoding: stdout, as: UTF8.self).contains(secret), "the sandbox read the pasteboard")
    }

    func testPlaceholdersExpandInOnePass() {
        XCTAssertEqual(ProviderSandbox.substitute("{source}|{out}|{x}|{", ["source": "{out}", "out": "/o"]),
                       "{out}|/o|{x}|{")
    }

    /// `./gen.sh` that is not in the folder is an error, never a PATH lookup for `gen.sh`.
    func testMissingProviderProgramIsRefused() async throws {
        var p = try provider(["missing.sh"])
        p.manifest?.generator?.providerRelative = true
        let runner = SpawnCountingRunner()
        do {
            _ = try await sandbox(runner: runner).run(p, outputDirectory: try output())
            XCTFail("expected programMissing")
        } catch {
            XCTAssertEqual(error as? ProviderSandboxError, .programMissing("missing.sh"))
        }
        XCTAssertEqual(runner.calls, 0)
    }

    /// A double fork into `setsid` leaves the group, so the timeout's group kill misses it, and
    /// it keeps stdout open. The run still ends on time, cleans up, and the holder is dead.
    func testEscapedPipeHolderIsKilledAndTheRunEndsOnTime() async throws {
        let marker = "\(Int.random(in: 7_000_000...7_999_999))"
        defer { CommandRunnerTests.pkill(marker) }
        let rescue = Task { try await Task.sleep(nanoseconds: 20_000_000_000); CommandRunnerTests.pkill(marker) }
        defer { rescue.cancel() }
        let perl = "exit 0 if fork; POSIX::setsid(); exit 0 if fork; exec '/bin/sleep', '\(marker)'"
        let start = Date()
        let result = try await sandbox().run(
            try provider(["/bin/sh", "-c", "/usr/bin/perl -MPOSIX -e \"\(perl)\"; exec /bin/sleep 300"], timeout: 1),
            outputDirectory: try output())
        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1 + 3)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("runs").path)) ?? [], [])
        XCTAssertFalse(CommandRunnerTests.alive(marker), "the escaped holder outlived the run")
    }

    private static func appears(_ url: URL, within seconds: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The probe was registered with LaunchServices by the control launch; leave no record of it.
    private static func unregister(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        p.arguments = ["-u", app.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    // MARK: - Caps

    /// The flood would go on for 30s; the stdout cap stops it at 1 MiB.
    func testStdoutFloodIsStopped() async throws {
        let start = Date()
        let result = try await sandbox().run(
            try provider(["/bin/sh", "-c", "head -c 4000000 /dev/zero; exec /bin/sleep 30"], timeout: 5),
            outputDirectory: try output())
        XCTAssertEqual(result, .outputTooLarge("stdout"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    /// Many small files, each far under the per-file cap, only add up past the folder cap.
    /// Rate-limited so the RED run (no cap) cannot fill the disk before its timeout.
    func testOutputFolderFloodIsStopped() async throws {
        let out = try output()
        let start = Date()
        let result = try await sandbox(limits: Self.small).run(
            try provider(["/bin/sh", "-c", "i=0; while :; do /bin/dd if=/dev/zero of=\"$1/f$i\" bs=65536 count=4 2>/dev/null; i=$((i+1)); /bin/sleep 0.02; done",
                          "sh", "{out}"], timeout: 5),
            outputDirectory: out)
        XCTAssertEqual(result, .outputTooLarge("out/"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testTempFolderFloodIsStopped() async throws {
        let start = Date()
        let result = try await sandbox(limits: Self.small).run(
            try provider(["/bin/sh", "-c", "i=0; while :; do /bin/dd if=/dev/zero of=\"$TMPDIR/f$i\" bs=65536 count=4 2>/dev/null; i=$((i+1)); /bin/sleep 0.02; done"],
                         timeout: 5),
            outputDirectory: try output())
        XCTAssertEqual(result, .outputTooLarge("tmp/"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    /// One file grows past the per-file cap faster than any periodic check could see it; the
    /// kernel stops the write at the cap.
    func testSingleFileOverTheCapIsStopped() async throws {
        let out = try output()
        let limits = ProviderSandbox.Limits(stdout: 1 << 20, output: 64 << 20, temp: 64 << 20, file: 1 << 20)
        let result = try await sandbox(limits: limits).run(
            try provider(["/bin/dd", "if=/dev/zero", "of={out}/big", "bs=65536", "count=64"]),
            outputDirectory: out)
        XCTAssertEqual(result, .outputTooLarge("file"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("big").path))
    }

    /// A timeout far past the parser's cap (a hand-built manifest) must not trap the
    /// nanosecond arithmetic; it is clamped to ten minutes.
    func testHugeTimeoutIsClamped() async throws {
        let result = try await sandbox().run(try provider(["/usr/bin/true"], timeout: Int.max), outputDirectory: try output())
        XCTAssertEqual(exited(result).code, 0)
    }

    // MARK: - Delivery

    /// An escaped process swaps a file for a link after the run. Delivery opens every entry
    /// with O_NOFOLLOW, so the link is refused rather than followed into the secret.
    func testFileSwappedForALinkBeforeDeliveryIsRefused() async throws {
        let secret = tmp.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let out = try output()
        var s = sandbox()
        s.beforeDelivery = { folder in
            let x = folder.appendingPathComponent("x")
            try? FileManager.default.removeItem(at: x)
            try? FileManager.default.createSymbolicLink(at: x, withDestinationURL: secret)
        }
        do {
            _ = try await s.run(try provider(["/bin/sh", "-c", "echo ok > \"$1/x\"", "sh", "{out}"]), outputDirectory: out)
            XCTFail("a swapped-in link was delivered")
        } catch {
            XCTAssertEqual(error as? ProviderSandboxError, .outputNotRegularFile("x"))
        }
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("x").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("x").path))
    }

    /// The same with a folder: `sub/` becomes a link to a folder holding a secret.
    func testFolderSwappedForALinkBeforeDeliveryIsRefused() async throws {
        let secrets = tmp.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: secrets.appendingPathComponent("y"))
        let out = try output()
        var s = sandbox()
        s.beforeDelivery = { folder in
            let sub = folder.appendingPathComponent("sub")
            try? FileManager.default.removeItem(at: sub)
            try? FileManager.default.createSymbolicLink(at: sub, withDestinationURL: secrets)
        }
        do {
            _ = try await s.run(try provider(["/bin/sh", "-c", "mkdir \"$1/sub\" && echo ok > \"$1/sub/y\"", "sh", "{out}"]),
                                outputDirectory: out)
            XCTFail("a swapped-in folder link was delivered")
        } catch {
            XCTAssertEqual(error as? ProviderSandboxError, .outputNotRegularFile("sub"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("sub/y").path))
    }

    /// A hard link is a regular file to `fstat`, but its bytes are whatever it was linked to,
    /// read by the unsandboxed app during delivery. The sandbox already refuses `ln` from the
    /// inside (measured: the generator-made link never appears), so the link is planted the way
    /// an escaped process would, through the hook. Only files with one link are delivered.
    func testHardLinkInOutputIsNotDelivered() async throws {
        let secret = tmp.appendingPathComponent("hard-secret.txt")
        try Data("secret".utf8).write(to: secret)
        let out = try output()
        var s = sandbox()
        s.beforeDelivery = { folder in
            let x = folder.appendingPathComponent("x")
            try? FileManager.default.removeItem(at: x)
            _ = link(secret.path, x.path)
        }
        do {
            _ = try await s.run(try provider(["/bin/sh", "-c", "echo ok > \"$1/x\"", "sh", "{out}"]), outputDirectory: out)
            XCTFail("a hard link was delivered")
        } catch {
            XCTAssertEqual(error as? ProviderSandboxError, .outputNotRegularFile("x"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("x").path))
    }

    // MARK: - Round 2

    /// The runner keeps stdout only to just past the cap, so a flood from a process outside the
    /// group, which the counter's group kill cannot reach, costs no memory either.
    func testStdoutCaptureIsPassedToTheRunner() async throws {
        let runner = CaptureRecordingRunner()
        _ = try? await sandbox(runner: runner).run(try provider(["/usr/bin/true"]), outputDirectory: try output())
        XCTAssertEqual(runner.capture, ProviderSandbox.Limits.standard.stdout + 1)
    }

    /// `kill` reached any process of the same user, Flight Deck included. Now only the sandbox's
    /// own processes, so a generator can still stop its children.
    func testSignalToAnOutsideProcessIsDenied() async throws {
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sleep")
        outside.arguments = ["300"]
        try outside.run()
        defer { outside.terminate() }
        let result = try await sandbox().run(try provider(["/bin/kill", "-TERM", "\(outside.processIdentifier)"]),
                                             outputDirectory: try output())
        XCTAssertNotEqual(exited(result).code, 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(outside.isRunning, "the sandbox signalled a process outside it")

        let own = try await sandbox().run(
            try provider(["/bin/sh", "-c", "/bin/sleep 30 & if kill $!; then echo stopped; fi; wait"]),
            outputDirectory: try output())
        guard case .exited(_, let stdout, _, _) = own else { return XCTFail("\(own)") }
        XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "stopped\n")
    }

    /// The user's temp folder holds other provider runs and the user's caches; /private/tmp
    /// holds other sessions' scratch files. Neither is readable; the run's own folder still is.
    func testUserTempAndPrivateTmpAreUnreadable() async throws {
        let secret = "secret-\(UUID().uuidString)"
        let inTemp = tmp.appendingPathComponent("planted.txt")
        try Data(secret.utf8).write(to: inTemp)
        let inPrivateTmp = URL(fileURLWithPath: "/private/tmp/fd-sandbox-probe-\(UUID().uuidString)")
        try Data(secret.utf8).write(to: inPrivateTmp)
        defer { try? FileManager.default.removeItem(at: inPrivateTmp) }
        for planted in [inTemp, inPrivateTmp] {
            let result = try await sandbox().run(try provider(["/bin/cat", planted.path]), outputDirectory: try output())
            guard case .exited(let code, let stdout, _, _) = result else { return XCTFail("\(result)") }
            XCTAssertNotEqual(code, 0, planted.path)
            XCTAssertFalse(String(decoding: stdout, as: UTF8.self).contains(secret), planted.path)
        }
        // The generator still works from its own folder.
        let own = try await sandbox().run(try provider(["/bin/cat", "provider.toml"]), outputDirectory: try output())
        XCTAssertEqual(exited(own).code, 0, exited(own).stderr)
    }

    /// `getpwuid` needs a Mach service the sandbox denies; USER and LOGNAME let `getpass` and
    /// friends answer without it.
    func testUserNameResolvesWithoutTheDirectoryService() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "no python3")
        let result = try await sandbox().run(
            try provider(["/usr/bin/python3", "-c", "import getpass; print(getpass.getuser())"]), outputDirectory: try output())
        guard case .exited(0, let stdout, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(String(decoding: stdout, as: UTF8.self), String(cString: getpwuid(getuid())!.pointee.pw_name) + "\n")
    }

    /// A program that ignores SIGXFSZ gets EFBIG and exits 1 on its own; the file left at the
    /// cap says why.
    func testFileCapIsReportedWhenSIGXFSZIsIgnored() async throws {
        let limits = ProviderSandbox.Limits(stdout: 1 << 20, output: 64 << 20, temp: 64 << 20, file: 1 << 20)
        let perl = "$SIG{XFSZ} = 'IGNORE'; open(my $f, '>', $ARGV[0]) or die; print $f '0' x (4 << 20) or die \"w: $!\\n\"; close $f or die \"c: $!\\n\""
        let result = try await sandbox(limits: limits).run(try provider(["/usr/bin/perl", "-e", perl, "{out}/big"]),
                                                           outputDirectory: try output())
        XCTAssertEqual(result, .outputTooLarge("file"))
    }

    // MARK: - Round 3

    /// `ulimit -f` counts 1024-byte blocks in bash but 512 in dash and zsh, and `/bin/sh` may be
    /// either: under dash a 1 MiB cap stopped files at 512 KiB. The launcher is bash, named.
    func testLauncherIsBash() async throws {
        let runner = CaptureRecordingRunner()
        _ = try? await sandbox(runner: runner).run(try provider(["/usr/bin/true"]), outputDirectory: try output())
        XCTAssertEqual(runner.executable, "/bin/bash")
    }

    /// Live: a program that ignores SIGXFSZ writes 4 MiB under a 1 MiB cap, then reports how far
    /// it got and removes the file. It must reach the cap, not half of it, and stop within a block.
    func testFileCapStopsAtTheCapNotHalfOfIt() async throws {
        let cap = 1 << 20
        let limits = ProviderSandbox.Limits(stdout: 1 << 20, output: 64 << 20, temp: 64 << 20, file: cap)
        let perl = "$SIG{XFSZ} = 'IGNORE'; my $p = \"$ENV{TMPDIR}/big\"; open(my $f, '>', $p) or die; "
            + "syswrite($f, '0' x 65536) for 1..64; close $f; print -s $p; unlink $p"
        let result = try await sandbox(limits: limits).run(try provider(["/usr/bin/perl", "-e", perl]),
                                                           outputDirectory: try output())
        guard case .exited(0, let stdout, _, _) = result else { return XCTFail("\(result)") }
        let reached = Int(String(decoding: stdout, as: UTF8.self)) ?? -1
        XCTAssertGreaterThanOrEqual(reached, cap)
        XCTAssertLessThanOrEqual(reached, cap + 1024)
    }

    /// A well-behaved file of exactly the cap is delivered, not reported as too large.
    func testFileOfExactlyTheCapIsDelivered() async throws {
        let out = try output()
        let limits = ProviderSandbox.Limits(stdout: 1 << 20, output: 64 << 20, temp: 64 << 20, file: 1 << 20)
        let result = try await sandbox(limits: limits).run(
            try provider(["/bin/dd", "if=/dev/zero", "of={out}/big", "bs=65536", "count=16"]), outputDirectory: out)
        guard case .exited(0, _, _, let outputs) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(outputs, ["big"])
        let size = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("big").path)[.size] as? Int
        XCTAssertEqual(size, 1 << 20)
    }

    /// The same class as /private/tmp: /private/var/tmp and /Users/Shared are world-writable
    /// scratch space other sessions leave files in, and the user's cache folder (`C/`) is theirs.
    func testSharedScratchFoldersAndTheUserCacheAreUnreadable() async throws {
        let secret = "secret-\(UUID().uuidString)"
        var planted = [URL(fileURLWithPath: "/private/var/tmp/fd-sandbox-probe-\(UUID().uuidString)"),
                       URL(fileURLWithPath: "/Users/Shared/fd-sandbox-probe-\(UUID().uuidString)")]
        let cache = URL(fileURLWithPath: try ProviderSandbox.userVarFolder()).appendingPathComponent("C")
        planted.append(cache.appendingPathComponent("fd-sandbox-probe-\(UUID().uuidString)"))
        defer { for url in planted { try? FileManager.default.removeItem(at: url) } }
        for url in planted {
            try Data(secret.utf8).write(to: url)
            let result = try await sandbox().run(try provider(["/bin/cat", url.path]), outputDirectory: try output())
            guard case .exited(let code, let stdout, _, _) = result else { return XCTFail("\(result)") }
            XCTAssertNotEqual(code, 0, url.path)
            XCTAssertFalse(String(decoding: stdout, as: UTF8.self).contains(secret), url.path)
        }
    }

    /// Every `/usr/bin` shim runs xcrun, which keeps its lookups in `$TMPDIR/xcrun_db`. A fresh
    /// run folder made every call cold (git --version ~1 s); the run starts with a copy of the
    /// user's cache instead.
    func testXcrunCacheIsWarm() async throws {
        let userCache = URL(fileURLWithPath: try ProviderSandbox.userTempFolder()).appendingPathComponent("xcrun_db")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: userCache.path), "this user has no xcrun cache")
        let probe = try await sandbox().run(try provider(["/bin/sh", "-c", "test -s \"$TMPDIR/xcrun_db\""]),
                                            outputDirectory: try output())
        XCTAssertEqual(exited(probe).code, 0, "the run's TMPDIR has no xcrun cache")
        let start = Date()
        let git = try await sandbox().run(try provider(["/usr/bin/git", "--version"]), outputDirectory: try output())
        print("[measure] testXcrunCacheIsWarm git --version \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        XCTAssertEqual(exited(git).code, 0, exited(git).stderr)
    }

    // MARK: - Round 4

    /// The user's own xcrun_db keys every HOME and temp folder xcrun ever ran under (project
    /// paths, other sessions' scratch folders). The cache a generator sees must name none of
    /// them: only Flight Deck's own seed folder and the toolchain.
    func testXcrunCacheNamesNoUserPaths() async throws {
        // Every user-folder or temp-folder path in the copy, one per line, inside the sandbox.
        let grep = "test -s \"$TMPDIR/xcrun_db\" || exit 3; "
            + "/usr/bin/grep -a -o -E '(/Users/|/var/folders/|/private/var/folders/|/private/tmp/|/tmp/)[^|[:cntrl:]]*' "
            + "\"$TMPDIR/xcrun_db\" | /usr/bin/sort -u | /usr/bin/head -c 500000; exit 0"
        let result = try await sandbox().run(try provider(["/bin/sh", "-c", grep]), outputDirectory: try output())
        guard case .exited(0, let stdout, _, _) = result else { return XCTFail("no seeded cache: \(result)") }
        let seed = try ProviderSandbox.realPath(ProviderSandbox.defaultXcrunSeedFolder)
        let foreign = String(decoding: stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(seed) }
        XCTAssertEqual(foreign, [], "the generator's xcrun cache names \(foreign.count) user or temp paths")
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
        p.manifest?.generator?.providerRelative = true
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

/// Runs nothing and remembers the stdout capture it was asked for.
private final class CaptureRecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Int?
    private var launched: String?
    var capture: Int? { lock.lock(); defer { lock.unlock() }; return recorded }
    var executable: String? { lock.lock(); defer { lock.unlock() }; return launched }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        CommandResult(stdout: Data(), stderr: "", exitCode: 0)
    }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?,
             onStdout: (@Sendable (Data) -> Void)?, stdoutCapture: Int?) async throws -> CommandResult {
        lock.lock(); recorded = stdoutCapture; launched = executable; lock.unlock()
        return CommandResult(stdout: Data(), stderr: "", exitCode: 0)
    }
}
