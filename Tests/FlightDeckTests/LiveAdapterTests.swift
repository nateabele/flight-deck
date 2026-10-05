import Foundation
import HostKit
import XCTest
@testable import FlightDeck

/// The live adapters against real temp repositories: what C2/C4/C5's types do once they sit
/// behind `DelegationService`'s seams.
@MainActor
final class LiveAdapterTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUp() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("live-adapters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        // realpath, as git reports it: `resolvingSymlinksInPath` keeps `/var` rather than `/private/var`.
        root = URL(fileURLWithPath: String(cString: realpath(temp.path, nil)))
        repo = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try write(".gitignore", "build/\n")
        try git("add", "-A")
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func git(_ args: String..., env: [String: String] = [:], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = repo
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }.merging(env) { $1 }
        let out = Pipe()
        let inPipe = Pipe()
        process.standardOutput = out
        process.standardInput = inPipe
        try process.run()
        if let input { try inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DelegationError(code: "git", message: args.joined(separator: " ")) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// What a host sends back: a snapshot of the worktree, a child commit setting `a.txt` to
    /// `text`, and a bundle carrying it.
    private func hostResult(_ text: String) async throws -> (snapshot: SnapshotRef, commit: String, bundle: URL) {
        let snapshot = try await LiveSnapshotter().snapshot(worktree: repo, host: "mini", include: [])
        let index = root.appendingPathComponent("host.index").path
        let env = ["GIT_INDEX_FILE": index]
        try git("read-tree", snapshot.commit, env: env)
        let blob = try git("hash-object", "-w", "--stdin", input: text)
        try git("update-index", "--cacheinfo", "100644,\(blob),a.txt", env: env)
        let tree = try git("write-tree", env: env)
        let commit = try git("-c", "user.name=h", "-c", "user.email=h@h", "commit-tree", tree, "-p", snapshot.commit,
                             "-m", "result")
        try git("update-ref", "refs/host/result", commit)
        let bundle = root.appendingPathComponent("result.bundle")
        try git("bundle", "create", "-q", bundle.path, "refs/host/result")
        try git("update-ref", "-d", "refs/host/result")
        return (snapshot, commit, bundle)
    }

    // MARK: LiveResultApplier

    func testPatchShowsTheHostsChangeAndLeavesNoRef() async throws {
        let result = try await hostResult("two\n")
        let patch = try await LiveResultApplier().patch(bundle: result.bundle, commit: result.commit,
                                                        snapshot: result.snapshot, worktree: repo)
        XCTAssertTrue(patch.contains("-one\n+two"), patch)
        XCTAssertEqual(try git("for-each-ref", "refs/flightdeck/results"), "")
    }

    func testAutoApplyWritesNothingWhenItWouldConflict() async throws {
        let result = try await hostResult("two\n")
        try write("a.txt", "mine\n")
        let outcome = try await LiveResultApplier().apply(bundle: result.bundle, commit: result.commit,
                                                          snapshot: result.snapshot, worktree: repo, allowConflicts: false)
        XCTAssertEqual(outcome, .conflicts(["a.txt"]))
        XCTAssertEqual(try read("a.txt"), "mine\n", "auto apply never writes markers")
        XCTAssertEqual(try git("for-each-ref", "refs/flightdeck/results"), "")
    }

    func testCleanApplyWritesTheResult() async throws {
        let result = try await hostResult("two\n")
        let outcome = try await LiveResultApplier().apply(bundle: result.bundle, commit: result.commit,
                                                          snapshot: result.snapshot, worktree: repo, allowConflicts: false)
        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(try read("a.txt"), "two\n")
    }

    func testReviewApplyLeavesConflictMarkers() async throws {
        let result = try await hostResult("two\n")
        try write("a.txt", "mine\n")
        let outcome = try await LiveResultApplier().apply(bundle: result.bundle, commit: result.commit,
                                                          snapshot: result.snapshot, worktree: repo, allowConflicts: true)
        XCTAssertEqual(outcome, .conflicts(["a.txt"]))
        XCTAssertTrue(try read("a.txt").contains("<<<<<<<"))
    }

    func testArtifactsReplaceOnlyIgnoredFiles() async throws {
        try write("build/out.txt", "old\n")
        let staging = root.appendingPathComponent("staging")
        for (path, text) in [("build/out.txt", "new\n"), ("a.txt", "clobbered\n"), ("report/x.txt", "fresh\n")] {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let tar = root.appendingPathComponent("artifacts.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", tar.path, "-C", staging.path, "build", "a.txt", "report"]
        try process.run()
        process.waitUntilExit()

        try await LiveResultApplier().extractArtifacts(tar: tar, into: repo)
        XCTAssertEqual(try read("build/out.txt"), "new\n", "ignored: replaced")
        XCTAssertEqual(try read("a.txt"), "one\n", "tracked: the user's")
        XCTAssertEqual(try read("report/x.txt"), "fresh\n", "absent: created")
    }

    func testUnsafePathsAreRefused() {
        XCTAssertFalse(LiveResultApplier.isSafe(".GIT/hooks/pre-commit", under: repo))
        XCTAssertFalse(LiveResultApplier.isSafe("../escape", under: repo))
        XCTAssertTrue(LiveResultApplier.isSafe("build/out.txt", under: repo))
        let mapped = LiveGitFailure.delegationError(SyncError.unsafePath(".git/x"), doing: "apply") as? DelegationError
        XCTAssertEqual(mapped?.code, "unsafe_path")
        let expired = LiveGitFailure.delegationError(SyncError.resultExpired, doing: "fetch") as? DelegationError
        XCTAssertEqual(expired?.code, "result_expired")
    }

    // MARK: Snapshot

    func testAnUnbornRepoIsRefusedWithItsCode() async throws {
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        repo = empty
        try git("init", "-q")
        do {
            _ = try await LiveSnapshotter().snapshot(worktree: empty, host: "mini", include: [])
            XCTFail("expected a refusal")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "unsupported")
            XCTAssertTrue(error.message.contains("commit once"), error.message)
        }
    }

    // MARK: Worktree

    func testLocateFindsTheRootAndSubdirOffMain() async throws {
        try write("src/deep/f.swift", "")
        let (worktree, subdir) = try await LiveWorktreeLocator().locate(cwd: repo.appendingPathComponent("src/deep"))
        XCTAssertEqual(worktree.path, repo.path)
        XCTAssertEqual(subdir, "src/deep")
        let ignored = await LiveWorktreeLocator().ignored(["build/x", "a.txt"], in: repo)
        XCTAssertEqual(ignored, ["build/x"])
    }

    // MARK: Config

    func testRecipesRoundTripAndCheckNamesProblems() throws {
        let loader = LiveConfigLoader(platforms: { ["linuxbox": "Linux"] })
        XCTAssertNil(try loader.load(worktree: repo))
        try loader.add(Recipe(run: "make test", screen: true), named: "ui", worktree: repo)
        let config = try XCTUnwrap(try loader.load(worktree: repo))
        XCTAssertEqual(config.recipes["ui"]?.run, "make test")
        XCTAssertEqual(loader.problems(in: config, hosts: ["linuxbox"]), [])

        try write(".flightdeck/delegate.toml", "default_host = \"linuxbox\"\n[recipe.ui]\nrun = \"x\"\nscreen = true\n")
        let linux = try XCTUnwrap(try loader.load(worktree: repo))
        let problems = loader.problems(in: linux, hosts: ["linuxbox"])
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("Linux host"), problems[0])
    }

    // MARK: Preflight

    private func plan(include: [String] = [], ports: [PortMapping] = [], screen: Bool = false,
                      service: Bool = false) -> DelegationPlan {
        DelegationPlan(host: "mini", worktree: repo, subdir: "",
                       spec: RunSpec(command: "x", subdir: "", env: [:], pty: false, screen: screen, service: service,
                                     downCommand: nil, ports: ports),
                       include: include, fetch: [], sync: true)
    }

    private func link(_ transport: ScriptedTransport) -> LiveHostLink {
        LiveHostLink(name: "mini", transport: transport, mirrors: root, mirrorPrefix: "slot")
    }

    func testPreflightRefusesAMissingInclude() async throws {
        do {
            _ = try await LivePreflight(forwarder: PortForwarder()).preflight(plan(include: [".env"]), link: link(ScriptedTransport()))
            XCTFail("expected a refusal")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "missing_include")
            XCTAssertTrue(error.message.hasPrefix(".env is in include"), error.message)
        }
    }

    func testPreflightChecksTheHostsCapabilitiesAndScreen() async throws {
        let old = ScriptedTransport()
        old.capabilities = [.hostInfo]
        do {
            _ = try await LivePreflight(forwarder: PortForwarder()).preflight(plan(), link: link(old))
            XCTFail("expected a refusal")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "unsupported")
        }

        let locked = ScriptedTransport()
        locked.answer = {
            guard case .screenStatus = $0 else { return nil }
            return .screenStatus(ScreenStatus(supported: true, consoleUser: true, locked: true, holder: nil, queued: 0))
        }
        do {
            _ = try await LivePreflight(forwarder: PortForwarder()).preflight(plan(screen: true), link: link(locked))
            XCTFail("expected a refusal")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "screen_locked")
        }
    }

    func testPreflightReleasesTheLocalPortWhenTheRemoteOneIsHeld() async throws {
        let held = ScriptedTransport()
        held.answer = {
            guard case .portCheck(let ports) = $0 else { return nil }
            return .portCheck(ports.map { PortStatus(port: $0, holder: .process(name: "postgres", pid: 9)) })
        }
        let forwarder = PortForwarder(timeWaitRetries: 0)
        let mapping = try PortMapping.parse("auto:5432")
        do {
            _ = try await LivePreflight(forwarder: forwarder).preflight(plan(ports: [mapping], service: true), link: link(held))
            XCTFail("expected a refusal")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "port_held")
            XCTAssertTrue(error.message.contains("postgres (pid 9)"), error.message)
        }
        XCTAssertTrue(held.sent.contains { if case .portCheck([5432]) = $0.request { return true } else { return false } })
    }

    func testPreflightPassesAndHoldsTheForward() async throws {
        let free = ScriptedTransport()
        free.answer = {
            guard case .portCheck(let ports) = $0 else { return nil }
            return .portCheck(ports.map { PortStatus(port: $0, holder: .free) })
        }
        let reservation = try await LivePreflight(forwarder: PortForwarder())
            .preflight(plan(ports: [try PortMapping.parse("auto:5432")], service: true), link: link(free))
        XCTAssertEqual(reservation.forwards.count, 1)
        XCTAssertEqual(reservation.forwards.first?.remote, 5432)
        reservation.release()
    }
}
