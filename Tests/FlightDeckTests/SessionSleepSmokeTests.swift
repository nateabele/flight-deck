import Darwin
import Foundation
import XCTest
@testable import FlightDeck

/// Composes the whole freeze/resume path — `SessionSleepController.tick()` → real
/// `PosixDaemonControl.stop` → real `PosixAgentGroupResolver` (`proc_listchildpids`/`getpgid`) →
/// a real forked process — against actual kernel signals, proving the pieces work *together*
/// against a live process and not just in isolation against spies/fixtures.
///
/// **Scope note.** This does not drive a real ghostty surface or a real `fd-abduco` daemon: the
/// surface-replay-on-reattach path is already covered by the detach work's own `fd-abduco` tests
/// and `TerminalSmokeTests`, and this controller's wake path reuses that unchanged. So
/// `tearDownSurface`/`rebuildSurface` stay spies here — everything else is real.
@MainActor
final class SessionSleepSmokeTests: XCTestCase {
    func testControllerSleepsAndWakesARealAgentWithRealSignals() throws {
        let tempDir = URL(fileURLWithPath: "/tmp/sss-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionDaemon = SessionDaemon(directory: tempDir, bundledBinary: nil)
        let control = PosixDaemonControl(daemon: sessionDaemon)
        let id = UUID()

        // The "daemon": a real `/bin/bash` process, its own process-group leader (same
        // `POSIX_SPAWN_SETPGROUP` idiom `ForkedChild`'s other spawns use). `set -m` turns job
        // control ON for this otherwise-non-interactive shell — without it, a backgrounded child
        // just inherits the shell's own pgid, and the eligibility math below would resolve to
        // the *daemon's* pgid, which (via real ppid) does have a live child: the agent itself.
        // With job control on, the backgrounded `sleep 30` becomes a real fork of the daemon
        // process (so `proc_listchildpids(daemonPID)` finds it, matching production's "daemon's
        // sole direct child") that lands in its OWN process group led by itself — a childless
        // leaf, so `descendants(of: agentPGID)` is empty and the session is eligible.
        //
        // Caveat: this gives the agent its own process *group*, not its own *session* the way
        // `setsid` does in production (see `PosixAgentGroupResolver`'s doc comment) — plain job
        // control is the closest a shell one-liner gets without a bespoke helper binary. The
        // property this test actually needs — the daemon keeps running while `SIGSTOP` lands
        // only on the agent's group — holds either way, and is exactly what the assertions below
        // check for.
        let daemonProcess = try ForkedChild.spawnOwnGroup(
            command: "/bin/bash", args: ["-c", "set -m; sleep 30 & wait"])
        var agentPGID: pid_t = 0
        defer {
            // The agent lives in its OWN group, separate from the daemon's — `daemonProcess.
            // terminate()`'s `kill(-daemonProcess.pid, …)` never reaches it, so it needs its own
            // cleanup or it would outlive this test by design (it's a 30s `sleep`).
            if agentPGID > 0 { kill(-agentPGID, SIGKILL) }
            daemonProcess.terminate()
        }

        try Data("\(daemonProcess.pid)\n".utf8)
            .write(to: URL(fileURLWithPath: sessionDaemon.pidfilePath(for: id)))

        // Poll for the daemon to have actually forked the agent and landed it in its own group
        // before driving the policy — `set -m` taking effect and the fork happening both race
        // this test's own startup, and a fixed sleep here would be exactly the kind of flake the
        // brief rules out.
        let resolver = PosixAgentGroupResolver()
        agentPGID = try waitForAgentGroup(resolver: resolver, daemonPID: daemonProcess.pid)

        var torn: [UUID] = []
        var rebuilt: [UUID] = []
        let controller = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0),   // sleep immediately once idle is recorded
            daemonControl: control,
            inspector: ProcessTree(),
            resolver: resolver,
            inputs: SleepInputs(
                candidates: { [id] },
                activity: { _ in .idle },
                selectedID: { nil },
                reportsBackgroundWork: { _ in false },
                daemonPID: { control.daemonPID($0) }),
            tearDownSurface: { torn.append($0) },
            rebuildSurface: { rebuilt.append($0) },
            sleepEnabled: { true },
            now: { Date() })

        // idleThreshold 0: idleSince is set to the same `now` this tick evaluates against, so
        // 0 >= 0 is already satisfied and this FIRST tick sleeps. The second is a no-op — `id`
        // is already in `asleep`, so the loop skips it.
        controller.tick()
        controller.tick()

        XCTAssertTrue(controller.asleep.contains(id))
        XCTAssertEqual(torn, [id])
        XCTAssertTrue(
            waitForProcessState(agentPGID, toBe: "T"), "the agent should be really SIGSTOP'd"
        )

        controller.wake(id)

        XCTAssertFalse(controller.asleep.contains(id))
        XCTAssertEqual(rebuilt, [id])
        XCTAssertTrue(
            waitForProcessState(agentPGID, leaving: "T"), "the agent should have really resumed"
        )
    }

    // MARK: - Helpers

    /// Polls `resolver.agentProcessGroup(daemonPID:)` — the same real call the controller itself
    /// drives — until the daemon's child (the agent) has forked and landed in its own process
    /// group, up to a couple of seconds (mirroring `DaemonControlTests.waitForPidfile`'s budget).
    private func waitForAgentGroup(
        resolver: AgentGroupResolving, daemonPID: pid_t
    ) throws -> pid_t {
        for _ in 0..<40 {
            if let pgid = resolver.agentProcessGroup(daemonPID: daemonPID) { return pgid }
            usleep(50_000)
        }
        throw TimedOut("agent process group under daemon pid \(daemonPID) never resolved")
    }

    /// The one-letter `ps` state code (`T` == stopped) for `pid`, so this observes the kernel's
    /// actual `SIGSTOP`/`SIGCONT` effect rather than trusting a spy — same helper as Task 7's
    /// `DaemonControlTests`.
    private func processState(_ pid: pid_t) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        return String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
    }

    /// Polls `processState(_:)` up to ~1s (same budget as `waitForAgentGroup`) for `pid` to
    /// reach `state`, so this can't race the kernel's actual delivery of the SIGSTOP/SIGCONT
    /// `stop`/`cont` just sent — a single snapshot right after `tick()`/`wake()` returns is not
    /// guaranteed to already reflect it.
    private func waitForProcessState(_ pid: pid_t, toBe state: String) -> Bool {
        for _ in 0..<20 {
            if processState(pid) == state { return true }
            usleep(50_000)
        }
        return false
    }

    /// Same poll, inverted: waits for `pid` to leave `state` rather than reach it — used for the
    /// post-wake assertion, where "no longer stopped" is what SIGCONT actually promises (it
    /// could resume through several other states, not just one target).
    private func waitForProcessState(_ pid: pid_t, leaving state: String) -> Bool {
        for _ in 0..<20 {
            if processState(pid) != state { return true }
            usleep(50_000)
        }
        return false
    }

    private struct TimedOut: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
