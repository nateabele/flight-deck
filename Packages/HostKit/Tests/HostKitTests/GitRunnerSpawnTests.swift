import XCTest
@testable import HostKit

/// How `GitRunner` starts git: in a process group of its own, so a cancel reaches everything
/// git started (ssh, a remote helper), and never anything else.
final class GitRunnerSpawnTests: XCTestCase {
    /// A fake ssh, standing in for a connection to a host that never answers: it records its
    /// pid, then waits on a child `sleep 300`. Cancelling the fetch must take both down; a
    /// kill that reached git alone left them running (and holding the run's slot) for 5 min.
    func testCancellingAFetchLeavesNoChildProcessBehind() async throws {
        #if !os(Linux)
        throw XCTSkip("reads /proc; the Linux run covers it")
        #else
        let scratch = TempRepo.scratch()
        let repo = scratch.appendingPathComponent("cache.git")
        try TempRepo.git(["init", "-q", "--bare", repo.path], in: scratch)
        let pidFile = scratch.appendingPathComponent("ssh.pid")
        let fakeSSH = scratch.appendingPathComponent("fake-ssh")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nsleep 300\n".utf8).write(to: fakeSSH)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

        let git = GitRunner(isolated: true)
        let ended = Done()
        let fetch = Task {
            defer { ended.set() }
            return try await GitRunner.offload {
                try git.run(["fetch", "-q", "ssh://example.invalid/lib.git", "main"], in: repo,
                            env: ["GIT_SSH_COMMAND": fakeSSH.path, "GIT_ALLOW_PROTOCOL": "ssh"])
            }
        }
        let deadline = Date().addingTimeInterval(20)
        var ssh: pid_t?
        while ssh == nil && Date() < deadline {
            ssh = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let sshPID = try XCTUnwrap(ssh, "the fake ssh never started")
        var sleeper: pid_t?
        while sleeper == nil && Date() < deadline {
            sleeper = Self.children(of: sshPID).first
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let sleepPID = try XCTUnwrap(sleeper, "the fake ssh's sleep never started")
        XCTAssertNotEqual(getpgid(sshPID), getpgrp(), "git runs in a process group of its own, not the host's")
        XCTAssertEqual(getpgid(sshPID), getpgid(sleepPID), "and everything it starts stays in it")

        fetch.cancel()
        // Bounded: a cancel that only looks done once the fake ssh's 300 s sleep ends would
        // otherwise pass, late. Measured: with `Process`, git's exit was not seen until then.
        let prompt = await ended.wait(seconds: 10)
        let gone = Date().addingTimeInterval(5)
        while (Self.alive(sshPID) || Self.alive(sleepPID)) && Date() < gone {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let survivors = [sshPID, sleepPID].filter(Self.alive)
        survivors.forEach { kill($0, SIGKILL) }   // a failure here must not leave them for 5 min
        XCTAssertTrue(prompt, "the cancelled fetch did not return within 10 s")
        XCTAssertEqual(survivors, [], "the fetch's children outlived its cancel")
        let error = await thrown { try await fetch.value }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        #endif
    }

    /// Alive and not a zombie (an orphan reparented to a PID 1 that does not reap stays one).
    static func alive(_ pid: pid_t) -> Bool {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return false }
        return stat[stat.index(close, offsetBy: 2)] != "Z"
    }

    static func children(of pid: pid_t) -> [pid_t] {
        let text = (try? String(contentsOfFile: "/proc/\(pid)/task/\(pid)/children", encoding: .utf8)) ?? ""
        return text.split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
