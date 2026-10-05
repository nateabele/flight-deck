import FleetKit
import Foundation
import HostKit
import XCTest
@testable import FlightDeck

/// `flightdeck run` against the real Linux hostd: the app's `DelegationService`, built by the
/// factory, over a TLS `HostLink` to `flightdeck-hostd serve` in `swift:6.3-noble`. The
/// loopback suite proves the same flow against the macOS hostd; this proves the NIO transport,
/// the Linux router, and a Linux git agree with a Mac controller on the wire.
///
/// Skipped unless `scripts/test-hostd-linux-interop.sh run` started the container; that
/// script fails a run in which this test was skipped.
@MainActor
final class LinuxHostdRunInteropTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-run-interop-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
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

    private final class Frames { var all: [ServerFrame] = [] }

    private func run(_ command: String, in repo: URL, on service: DelegationService) async throws
        -> (output: String, exit: Int32?, runID: String?, frames: [ServerFrame]) {
        let frames = Frames()
        service.handle(.run(WireDelegateRun(cwd: repo.path, host: "linux", command: [command])), caller: .human,
                       cid: 1) { frames.all.append($0) }
        try await waitUntil(timeout: 120) {
            frames.all.contains { if case .delegateExit = $0 { return true }; if case .err = $0 { return true }; return false }
        }
        var output = "", exit: Int32?, runID: String?
        for frame in frames.all {
            switch frame {
            case .delegateOutput(_, _, _, let data): output += String(decoding: data, as: UTF8.self)
            case .delegateExit(_, let status): exit = status
            case .delegateStarted(_, let started): runID = started.runID
            default: break
            }
        }
        return (output, exit, runID, frames.all)
    }

    func testDelegatedRunAgainstLinuxHostd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["FD_LINUX_HOSTD_ENDPOINT"], env["FD_LINUX_HOSTD_MODE"] == "run" else {
            throw XCTSkip("Linux hostd not running in run mode")
        }
        let state = root.appendingPathComponent("controller", isDirectory: true)
        let registry = HostRegistry(fileURL: state.appendingPathComponent("hosts.json"), secrets: InMemoryHostSecretStore())
        let key = FleetDeviceKey(slot: LinuxHostdInteropTests.slot, secret: LinuxHostdInteropTests.secret)
        _ = try registry.add(key: key, name: "linux", serviceName: "fd-interop-none", endpoints: [endpoint])
        let hosts = HostService(registry: registry, controllerName: "interop")
        hosts.start()
        defer { hosts.forget(slot: key.slot) }
        try await waitUntil(timeout: 60) { if case .online = hosts.statuses[key.slot] { true } else { false } }
        let service = DelegationServiceFactory.live(hostService: hosts, stateDirectory: state)

        let repo = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try Data("alpha\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        // Uncommitted, so the sync has to carry the working tree, not just the commit.
        try Data("edited on the Mac\n".utf8).write(to: repo.appendingPathComponent("a.txt"))

        let echo = try await run("echo hello from $(uname -s)", in: repo, on: service)
        XCTAssertEqual(echo.output, "hello from Linux\n", "\(echo.frames)")
        XCTAssertEqual(echo.exit, 0)

        // A real git in the synced checkout on the host: clean, at the snapshot's commit, with
        // the Mac's uncommitted edit in it.
        let status = try await run("git status --porcelain && git rev-parse HEAD && cat a.txt", in: repo, on: service)
        XCTAssertEqual(status.exit, 0, "\(status.frames)")
        let snapshot = try XCTUnwrap(status.runID.flatMap { service.registry.run($0)?.snapshot })
        XCTAssertEqual(status.output, "\(snapshot.commit)\nedited on the Mac\n")
    }
}
