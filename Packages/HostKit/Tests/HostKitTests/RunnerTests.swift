import XCTest
@testable import HostKit
#if canImport(Glibc)
import Glibc
#endif

/// Every test here drives real child processes through `/bin/sh`: process groups, traps and
/// ptys are kernel behavior, and a fake would only test the fake.
final class RunnerTests: XCTestCase {
    // MARK: - Fixtures

    /// Escalation sleeps suspend until the test advances them, so a 10 s grace costs nothing
    /// and the test controls exactly when each signal goes out.
    private final class ManualClock: RunClock, @unchecked Sendable {
        private let lock = NSLock()
        private var sleepers: [CheckedContinuation<Void, Never>] = []
        private var asked: [Double] = []

        func sleep(seconds: Double) async {
            await withCheckedContinuation { cont in
                lock.withLock {
                    asked.append(seconds)
                    sleepers.append(cont)
                }
            }
        }

        var requested: [Double] { lock.withLock { asked } }

        /// Waits for a sleeper to exist, then wakes it.
        func advance(file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let next: CheckedContinuation<Void, Never>? = lock.withLock {
                    sleepers.isEmpty ? nil : sleepers.removeFirst()
                }
                if let next { next.resume(); return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("nothing was sleeping on the clock", file: file, line: line)
        }
    }

    private final class RecordingPower: PowerAsserting, @unchecked Sendable {
        private let lock = NSLock()
        private var live: [Int: PowerAssertionKind] = [:]
        private var next = 0
        private var ever: [PowerAssertionKind] = []

        func hold(_ kind: PowerAssertionKind, reason: String) -> PowerAssertion {
            let id: Int = lock.withLock {
                next += 1
                live[next] = kind
                ever.append(kind)
                return next
            }
            return PowerAssertion { [weak self] in
                guard let self else { return }
                self.lock.withLock { _ = self.live.removeValue(forKey: id) }
            }
        }

        var held: [PowerAssertionKind] { lock.withLock { live.values.sorted { "\($0)" < "\($1)" } } }
        var everHeld: [PowerAssertionKind] { lock.withLock { ever } }
    }

    private struct FixedConsole: ConsoleSessionProbing {
        let state: ConsoleSession
        func current() -> ConsoleSession { state }
    }

    private let consoleAvailable = ConsoleSession(supported: true, consoleUser: true, locked: false)

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func checkout() throws -> CheckoutLease {
        let ref = SnapshotRef(repoRoot: "root", wtKey: "wt", worktreeName: "repo", commit: "c", tree: "t")
        return CheckoutLease(id: UUID(), path: try tempDir("checkout"), slot: 0, ref: ref)
    }

    private let hostEnv: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSTemporaryDirectory(),
    ]

    private func runner(clock: any RunClock = SystemRunClock(),
                        power: any PowerAsserting = NoPowerAssertions(),
                        console: ConsoleSession? = nil,
                        hostEnvironment: [String: String]? = nil) throws -> Runner {
        Runner(runsRoot: try tempDir("runs"), shell: "/bin/sh",
               hostEnvironment: hostEnvironment ?? hostEnv, clock: clock, power: power,
               console: FixedConsole(state: console ?? consoleAvailable))
    }

    private func start(_ r: Runner, _ spec: RunSpec, _ lease: CheckoutLease, owner: String = "A") -> String {
        r.start(spec, owner: LeaseHolderOwner(controller: controllerID, session: owner), acquire: { lease })
    }

    private let controllerID = UUID()

    private func spec(_ command: String, subdir: String = "", env: [String: String] = [:],
                      pty: Bool = false, screen: Bool = false, ptySize: TerminalSize? = nil) -> RunSpec {
        RunSpec(command: command, subdir: subdir, env: env, pty: pty, screen: screen, service: false,
                downCommand: nil, ports: [], ptySize: ptySize)
    }

    /// Collects events until the run ends, failing rather than hanging past `timeout`.
    private func collect(_ runner: Runner, _ id: String, from offset: Int64 = 0,
                         timeout: TimeInterval = 30) async throws -> [RunEvent] {
        try await withThrowingTaskGroup(of: [RunEvent]?.self) { group in
            group.addTask {
                var out: [RunEvent] = []
                for try await ev in runner.events(runID: id, from: offset) { out.append(ev) }
                return out
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            return try XCTUnwrap(first, "run \(id) did not end within \(timeout)s")
        }
    }

    private func output(_ events: [RunEvent], _ stream: RunOutputStream? = nil) -> String {
        events.reduce(into: "") { text, ev in
            if case .output(let s, _, let data) = ev, stream == nil || s == stream {
                text += String(decoding: data, as: UTF8.self)
            }
        }
    }

    private func exit(_ events: [RunEvent]) -> RunExit? {
        for ev in events { if case .exited(let e) = ev { return e } }
        return nil
    }

    /// Reads live events until `predicate` holds over the output so far.
    private func waitForOutput(_ runner: Runner, _ id: String,
                               _ predicate: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var text = ""
                for try await ev in runner.events(runID: id, from: 0) {
                    if case .output(_, _, let data) = ev { text += String(decoding: data, as: UTF8.self) }
                    if predicate(text) { return text }
                }
                return text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            return try XCTUnwrap(first, "output never matched")
        }
    }


    private func realPath(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.path }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: - Exit mapping

    func testExitCodeAndSignalMapping() async throws {
        let r = try runner()
        let lease = try checkout()

        let ok = try await collect(r, start(r, spec("echo hi"), lease))
        XCTAssertEqual(exit(ok), .code(0))
        XCTAssertEqual(output(ok, .stdout), "hi\n")
        if case .started = ok.first {} else { XCTFail("a run opens with its state: \(ok)") }

        let three = try await collect(r, start(r, spec("echo oops >&2; exit 3"), lease))
        XCTAssertEqual(exit(three), .code(3))
        XCTAssertEqual(exit(three)?.cliStatus, 3)
        XCTAssertEqual(output(three, .stderr), "oops\n")

        let killed = try await collect(r, start(r, spec("kill -TERM $$"), lease))
        XCTAssertEqual(exit(killed), .signal(SIGTERM))
        XCTAssertEqual(exit(killed)?.cliStatus, 128 + SIGTERM)
    }

    // MARK: - Signals

    func testCancelEscalatesIntToTermToKill() async throws {
        let clock = ManualClock()
        let r = try runner(clock: clock)
        // Traps both, so only SIGKILL can end it. Each trap prints, which proves the order.
        let id = start(r, spec("""
            trap 'echo got-INT' INT
            trap 'echo got-TERM' TERM
            echo ready
            while :; do sleep 0.1; done
            """), try checkout())
        _ = try await waitForOutput(r, id) { $0.contains("ready") }

        r.cancel(runID: id)
        let beforeTerm = try await waitForOutput(r, id) { $0.contains("got-INT") }
        XCTAssertFalse(beforeTerm.contains("got-TERM"), "TERM waits for the grace period")

        try await clock.advance()
        _ = try await waitForOutput(r, id) { $0.contains("got-TERM") }
        try await clock.advance()

        let events = try await collect(r, id)
        XCTAssertEqual(exit(events), .signal(SIGKILL))
        XCTAssertEqual(exit(events)?.cliStatus, 137)
        XCTAssertEqual(clock.requested, [10, 10])
        let text = output(events)
        XCTAssertLessThan(text.range(of: "got-INT")!.lowerBound, text.range(of: "got-TERM")!.lowerBound)
    }

    /// A background job of a non-interactive shell ignores SIGINT, so a cancel aimed only at the
    /// leader would leave it running in the checkout the next run is about to reuse.
    func testProcessGroupKilledIncludingGrandchildren() async throws {
        let r = try runner(clock: ManualClock())
        let id = start(r, spec("sleep 300 & echo $!; wait"), try checkout())
        let line = try await waitForOutput(r, id) { $0.hasSuffix("\n") }
        let grandchild = try XCTUnwrap(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(grandchild, 0), 0, "grandchild is running")

        r.cancel(runID: id)
        let events = try await collect(r, id)
        XCTAssertNotNil(exit(events))

        let deadline = Date().addingTimeInterval(10)
        while !isDead(grandchild) && Date() < deadline { usleep(50_000) }
        XCTAssertTrue(isDead(grandchild), "the grandchild died with its group")
    }

    /// Gone, or a zombie: in the Linux container the orphan is reparented to a PID 1 that never
    /// reaps, so a dead grandchild still answers `kill(pid, 0)`.
    private func isDead(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == -1 && errno == ESRCH { return true }
        #if os(Linux)
        let stat = (try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)) ?? ""
        // "pid (comm) S ...": the state follows the last ')'.
        if let close = stat.lastIndex(of: ")") {
            return stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z")
        }
        #endif
        return false
    }

    func testSignalForwardsToTheGroup() async throws {
        let r = try runner()
        let id = start(r, spec("trap 'echo got-USR1; exit 7' USR1; echo ready; while :; do sleep 0.1; done"), try checkout())
        _ = try await waitForOutput(r, id) { $0.contains("ready") }
        try r.signal(runID: id, SIGUSR1)
        let events = try await collect(r, id)
        XCTAssertEqual(exit(events), .code(7))
        XCTAssertTrue(output(events).contains("got-USR1"))
        XCTAssertThrowsError(try r.signal(runID: "nope", SIGINT))
    }

    // MARK: - Environment and working directory

    func testEnvIsHostPlusSpecOnly() async throws {
        // In this process (standing in for anything the controller had) but not in hostEnvironment.
        setenv("FD_C3_CONTROLLER_ONLY", "leak", 1)
        defer { unsetenv("FD_C3_CONTROLLER_ONLY") }
        var host = hostEnv
        host["FD_HOST"] = "host"
        host["FD_BOTH"] = "host"
        let r = try runner(hostEnvironment: host)
        let events = try await collect(r, start(r, spec("env", env: ["FD_SPEC": "spec", "FD_BOTH": "spec"]), try checkout()))
        let lines = Set(output(events, .stdout).split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("FD_HOST=host"))
        XCTAssertTrue(lines.contains("FD_SPEC=spec"))
        XCTAssertTrue(lines.contains("FD_BOTH=spec"), "the spec overrides the host")
        XCTAssertFalse(lines.contains { $0.hasPrefix("FD_C3_CONTROLLER_ONLY=") }, "only the host's env and the spec's")
    }

    func testSubdirEscapeRefused() async throws {
        let r = try runner()
        let lease = try checkout()
        let outside = try tempDir("outside")
        try FileManager.default.createDirectory(at: lease.path.appendingPathComponent("sub/deeper"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lease.path.appendingPathComponent("link"),
                                                   withDestinationURL: outside)

        for bad in ["..", "../x", "sub/../../x", "/etc", "link"] {
            do {
                _ = try await collect(r, start(r, spec("echo ran", subdir: bad), lease))
                XCTFail("\(bad) should be refused")
            } catch RunnerError.subdirEscapes(let s) {
                XCTAssertEqual(s, bad)
            }
        }
        do {
            _ = try await collect(r, start(r, spec("echo ran", subdir: "absent"), lease))
            XCTFail("a missing subdir should fail")
        } catch RunnerError.missingSubdir(let s) {
            XCTAssertEqual(s, "absent")
        }

        let events = try await collect(r, start(r, spec("pwd -P", subdir: "sub/deeper"), lease))
        XCTAssertEqual(output(events, .stdout), realPath(lease.path.appendingPathComponent("sub/deeper")) + "\n")
        let root = try await collect(r, start(r, spec("pwd -P"), lease))
        XCTAssertEqual(output(root, .stdout), realPath(lease.path) + "\n")
    }

    // MARK: - Pty

    func testPtyGetsTTY() async throws {
        let r = try runner()
        let events = try await collect(r, start(r,
            spec("test -t 0 && test -t 1 && test -t 2 && echo is-tty; stty size; exec 3</dev/tty && echo has-ctty",
                 pty: true, ptySize: TerminalSize(columns: 100, rows: 40)),
            try checkout()))
        let text = output(events, .pty)
        XCTAssertTrue(text.contains("is-tty"), text)
        XCTAssertTrue(text.contains("40 100"), "sized from the CLI's terminal: \(text)")
        XCTAssertTrue(text.contains("has-ctty"), "the pty is the controlling terminal, so ^C and job control work: \(text)")
        XCTAssertEqual(output(events, .stdout) + output(events, .stderr), "", "a pty run has one stream")
        XCTAssertEqual(exit(events), .code(0))
    }

    /// Darwin drops what the master has not read when the last slave descriptor closes, so a
    /// run that writes a burst and exits must still deliver every byte.
    func testPtyKeepsTheFinalBurst() async throws {
        let r = try runner()
        let events = try await collect(r, start(r, spec("head -c 200000 /dev/zero | tr '\\0' a", pty: true), try checkout()))
        XCTAssertEqual(output(events, .pty).filter { $0 == "a" }.count, 200_000)
    }

    // MARK: - Spool and reattach

    func testRunSurvivesNoSubscribers() async throws {
        let r = try runner()
        let id = start(r, spec("i=0; while [ $i -lt 50 ]; do echo line$i; i=$((i+1)); done"), try checkout())
        let deadline = Date().addingTimeInterval(20)
        while r.phase(runID: id)?.isTerminal == false && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(r.phase(runID: id), .exited(.code(0)), "it ran to the end with nobody listening")

        let events = try await collect(r, id)
        let expected = (0..<50).map { "line\($0)\n" }.joined()
        XCTAssertEqual(output(events, .stdout), expected)
        XCTAssertEqual(exit(events), .code(0))
    }

    /// Review Focus 2: the laptop sleeps mid-run, and the reattached stream neither loses nor
    /// repeats a byte.
    func testReattachResumesFromOffset() async throws {
        let r = try runner()
        let id = start(r, spec("""
            i=0
            while [ $i -lt 400 ]; do
              echo "line $i"
              i=$((i+1))
              [ $((i % 50)) -eq 0 ] && sleep 0.05
            done
            """), try checkout())

        // First connection: take some output, then drop mid-run.
        var firstPart = ""
        var resumeAt: Int64 = 0
        for try await ev in r.events(runID: id, from: 0) {
            if case .output(_, let offset, let data) = ev {
                XCTAssertEqual(offset, resumeAt, "contiguous")
                firstPart += String(decoding: data, as: UTF8.self)
                resumeAt = offset + Int64(data.count)
                if resumeAt > 500 { break }
            }
        }

        let rest = try await collect(r, id, from: resumeAt)
        // Replay order: the run's current state, then output from the offset, then its exit.
        XCTAssertEqual(rest.first, .started(runID: id))
        if case .output(_, let offset, _) = rest.dropFirst().first {
            XCTAssertEqual(offset, resumeAt, "resumes exactly where the first connection stopped")
        } else {
            XCTFail("output follows the state: \(rest.prefix(2))")
        }
        let expected = (0..<400).map { "line \($0)\n" }.joined()
        XCTAssertEqual(firstPart + output(rest), expected)
        XCTAssertEqual(rest.last, .exited(.code(0)))
    }

    func testOutputChunksAreAtMost64KiB() async throws {
        let r = try runner()
        let events = try await collect(r, start(r, spec("head -c 300000 /dev/zero"), try checkout()))
        var total = 0
        for case .output(_, _, let data) in events {
            XCTAssertLessThanOrEqual(data.count, 64 * 1024)
            total += data.count
        }
        XCTAssertEqual(total, 300_000)
    }

    // MARK: - Screen

    /// Review Focus 4: two agents want the mini's screen. The second queues with the holder
    /// named, and runs once the first is cancelled.
    func testSecondScreenRunQueuesThenRunsAfterCancel() async throws {
        let power = RecordingPower()
        let r = try runner(power: power)
        let first = start(r, spec("echo first-ready; sleep 300", screen: true), try checkout(), owner: "Agent A")
        _ = try await waitForOutput(r, first) { $0.contains("first-ready") }
        XCTAssertEqual(power.held, [.displaySleep, .idleSleep])

        let second = start(r, spec("echo second-ran", screen: true), try checkout(), owner: "Agent B")
        XCTAssertEqual(r.phase(runID: second), .queued(.screen))
        let holder = LeaseHolder(runID: first, session: "Agent A")
        XCTAssertEqual(r.screenStatus(), ScreenStatus(supported: true, consoleUser: true, locked: false,
                                                      holder: holder, queued: 1))

        // Attached while it waits: the current state comes first, naming who holds the screen.
        var live = r.events(runID: second, from: 0).makeAsyncIterator()
        let firstEvent = try await live.next()
        XCTAssertEqual(firstEvent, .queued(position: 1, on: .screen, holder: holder))

        r.cancel(runID: first)
        let firstEvents = try await collect(r, first)
        XCTAssertEqual(exit(firstEvents), .signal(SIGINT))

        var rest: [RunEvent] = []
        while let ev = try await live.next() { rest.append(ev) }
        XCTAssertEqual(rest.first, .started(runID: second))
        XCTAssertTrue(output(rest).contains("second-ran"))
        XCTAssertEqual(exit(rest), .code(0))
        XCTAssertNil(r.screenStatus().holder)
        XCTAssertEqual(power.held, [], "every assertion released once the runs end")
    }

    func testCancelledQueuedScreenRunNeverStarts() async throws {
        let r = try runner()
        let first = start(r, spec("sleep 300", screen: true), try checkout())
        let second = start(r, spec("echo must-not-run", screen: true), try checkout(), owner: "B")
        r.cancel(runID: second)
        let events = try await collect(r, second)
        XCTAssertEqual(events, [.exited(.signal(SIGINT))])
        XCTAssertEqual(r.screenStatus().queued, 0)
        r.cancel(runID: first)
        _ = try await collect(r, first)
    }

    /// A run waiting for a pool slot can be cancelled too; a slot that arrives afterwards goes
    /// straight back.
    func testCancelWhileWaitingForSlotReleasesTheLateSlot() async throws {
        let released = LeaseLog()
        let r = Runner(runsRoot: try tempDir("runs"), shell: "/bin/sh", hostEnvironment: hostEnv,
                       console: FixedConsole(state: consoleAvailable),
                       lifecycle: RunLifecycle(atExit: { _, _, _ in }, release: { released.add($0) }))
        let lease = try checkout()
        let gate = Gate()
        let id = r.start(spec("echo must-not-run"), owner: LeaseHolderOwner(controller: controllerID, session: "A")) {
            await gate.wait()
            return lease
        }
        var live = r.events(runID: id, from: 0).makeAsyncIterator()
        let waiting = try await live.next()
        XCTAssertEqual(waiting, .queued(position: 1, on: .slot, holder: nil), "a slow slot is reported")

        r.cancel(runID: id)
        await gate.open()
        var rest: [RunEvent] = []
        while let ev = try await live.next() { rest.append(ev) }
        XCTAssertEqual(rest, [.exited(.signal(SIGINT))])
        // The exit is reported at the cancel, by design, and the late slot goes back whenever
        // `acquire` returns: asserting it the instant the stream ends raced that task, and
        // failed under load.
        let deadline = Date().addingTimeInterval(5)
        while released.all.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(released.all, [lease])
    }

    func testLinuxRefusesScreen() async throws {
        let r = try runner(console: .unsupported)
        do {
            _ = try await collect(r, start(r, spec("echo x", screen: true), try checkout()))
            XCTFail("screen must be refused")
        } catch RunnerError.screenUnsupported {}
        XCTAssertFalse(r.screenStatus().supported)
        #if os(Linux)
        XCTAssertEqual(ConsoleSession.platformDefault.current(), .unsupported)
        #endif
    }

    func testScreenPreflightRefusesLockedOrNoConsole() async throws {
        let locked = try runner(console: ConsoleSession(supported: true, consoleUser: true, locked: true))
        do {
            _ = try await collect(locked, start(locked, spec("echo x", screen: true), try checkout()))
            XCTFail("locked")
        } catch RunnerError.screenLocked {}

        let nobody = try runner(console: ConsoleSession(supported: true, consoleUser: false, locked: false))
        do {
            _ = try await collect(nobody, start(nobody, spec("echo x", screen: true), try checkout()))
            XCTFail("no console user")
        } catch RunnerError.noConsoleUser {}
    }

    // MARK: - Services and lifecycle

    func testDownTermsThenRunsDownCommandAndNeverReportsDied() async throws {
        let r = try runner()
        var service = spec("trap 'echo got-TERM; exit 0' TERM; echo up; while :; do sleep 0.1; done")
        service.service = true
        service.downCommand = "echo down-ran"
        let id = start(r, service, try checkout())
        _ = try await waitForOutput(r, id) { $0.contains("up") }
        try await r.down(runID: id)
        let events = try await collect(r, id)
        let text = output(events)
        XCTAssertTrue(text.contains("got-TERM"), text)
        XCTAssertTrue(text.contains("down-ran"), text)
        XCTAssertLessThan(text.range(of: "got-TERM")!.lowerBound, text.range(of: "down-ran")!.lowerBound)
        XCTAssertEqual(events.last, .exited(.code(0)))
    }

    func testServiceThatDiesOnItsOwnReportsServiceDied() async throws {
        let r = try runner()
        var service = spec("exit 4")
        service.service = true
        let events = try await collect(r, start(r, service, try checkout()))
        XCTAssertEqual(events.last, .serviceDied(.code(4)))
    }

    /// Artifacts are captured while the run still holds its slot: released first, the next
    /// run's checkout would wipe them.
    func testAtExitRunsBeforeReleaseAndBeforeExitIsReported() async throws {
        let log = LeaseLog()
        let r = Runner(runsRoot: try tempDir("runs"), shell: "/bin/sh", hostEnvironment: hostEnv,
                       console: FixedConsole(state: consoleAvailable),
                       lifecycle: RunLifecycle(atExit: { lease, runID, spec in log.note("atExit \(runID) \(spec.fetch)") },
                                               release: { _ in log.note("release") }))
        var s = spec("echo hi")
        s.fetch = ["build/*.xcresult"]
        let id = start(r, s, try checkout())
        let events = try await collect(r, id)
        XCTAssertEqual(exit(events), .code(0))
        XCTAssertEqual(log.notes, ["atExit \(id) [\"build/*.xcresult\"]", "release"])
    }

    func testOwnerIsExposedForControllerScoping() throws {
        let r = try runner()
        let lease = try checkout()
        let id = start(r, spec("true"), lease, owner: "Agent A")
        XCTAssertEqual(r.owner(runID: id), LeaseHolderOwner(controller: controllerID, session: "Agent A"))
        XCTAssertNil(r.owner(runID: "nope"))
    }

    // MARK: - Review fix round 1

    private func openFDCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// hostd is a LaunchAgent with a soft limit of 256 fds: a spool that kept its handles after
    /// the run ended made `pipe()` fail with EMFILE after about 100 runs, and every run after.
    func testFinishedRunsLeaveOpenFdCountFlat() async throws {
        let r = try runner()
        let lease = try checkout()
        for _ in 0..<10 { _ = try await collect(r, start(r, spec("echo warm; echo up >&2"), lease)) }
        let before = openFDCount()
        for _ in 0..<300 { _ = try await collect(r, start(r, spec("echo out; echo err >&2"), lease)) }
        let after = openFDCount()
        XCTAssertLessThanOrEqual(after, before + 2, "fds before \(before), after \(after)")
        XCTAssertLessThanOrEqual(r.retainedRunCount, Runner.retainedFinishedRuns)
    }

    func testPrunesRunDirectoriesOlderThanADay() throws {
        let root = try tempDir("runs")
        let old = root.appendingPathComponent("r1"), fresh = root.appendingPathComponent("r2")
        for dir in [old, fresh] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: old.path)
        _ = Runner(runsRoot: root, shell: "/bin/sh", hostEnvironment: hostEnv, console: FixedConsole(state: consoleAvailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a day-old spool is pruned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// A screen run whose slot never came must give the screen back, or every later screen
    /// run on the host waits forever.
    func testFailedScreenAcquireReleasesTheLease() async throws {
        let r = try runner()
        struct NoSlot: Error {}
        let failed = r.start(spec("echo never", screen: true),
                             owner: LeaseHolderOwner(controller: controllerID, session: "A")) { throw NoSlot() }
        do {
            _ = try await collect(r, failed)
            XCTFail("the acquire error ends the run")
        } catch is NoSlot {}
        XCTAssertNil(r.screenStatus().holder)

        let next = try await collect(r, start(r, spec("echo next-ran", screen: true), try checkout()))
        XCTAssertTrue(output(next).contains("next-ran"))
        XCTAssertEqual(exit(next), .code(0))
    }

    /// The leader exits with a burst still in the pipe and a slow disk behind the spool: the
    /// run must wait for EOF, not escalate on a timer and cut the tail, and nothing may be
    /// appended once the exit is reported.
    func testSlowSpoolKeepsTheFinalBurstAndNothingFollowsExit() async throws {
        let r = try runner()
        // Each append outlasts the old fixed 3 s drain budget on its own.
        r.appendHook = { usleep(3_500_000) }
        let id = start(r, spec("head -c 150000 /dev/zero | tr '\\0' a"), try checkout())
        let events = try await collect(r, id, timeout: 120)
        XCTAssertEqual(output(events, .stdout).count, 150_000)
        XCTAssertEqual(events.last, .exited(.code(0)))
        let replay = try await collect(r, id)
        try await Task.sleep(nanoseconds: 500_000_000)
        let later = try await collect(r, id)
        XCTAssertEqual(output(replay).count, 150_000)
        XCTAssertEqual(later, replay, "the spool did not grow after the exit")
    }

    /// A cancelled run waiting on a slot that never arrives ends at once.
    func testCancelWhileSlotNeverArrivesEndsAtOnce() async throws {
        let r = try runner()
        let gate = Gate()
        let id = r.start(spec("echo must-not-run"), owner: LeaseHolderOwner(controller: controllerID, session: "A")) {
            await gate.wait()
            throw CancellationError()
        }
        r.cancel(runID: id)
        let events = try await collect(r, id, timeout: 5)
        XCTAssertEqual(events, [.exited(.signal(SIGINT))])
        XCTAssertEqual(r.phase(runID: id), .exited(.signal(SIGINT)))
    }

    /// Only fds 0–2 reach a run: hostd's sockets and other runs' pipes stay out of it.
    func testParentFdWithoutCloexecIsNotInherited() async throws {
        let base = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(base, 0)
        let fd = fcntl(base, F_DUPFD, 150)   // no CLOEXEC on purpose
        close(base)
        defer { close(fd) }
        let r = try runner()
        let events = try await collect(r, start(r, spec("if [ -e /dev/fd/\(fd) ]; then echo leaked; else echo clean; fi"),
                                                try checkout()))
        XCTAssertEqual(output(events, .stdout), "clean\n")
    }

    /// A spool write that fails (disk full) is reported in the stream, not silently lost.
    func testFailedAppendLeavesAMarker() async throws {
        let r = try runner()
        let failures = Counter(limit: 1)
        struct DiskFull: Error {}
        r.appendHook = { if failures.take() { throw DiskFull() } }
        let events = try await collect(r, start(r, spec("echo first; sleep 0.2; echo second"), try checkout()))
        let text = output(events)
        XCTAssertTrue(text.contains("lost"), text)
        XCTAssertTrue(text.contains("second"), text)
    }

    // MARK: - C3 follow-ups (C8)

    /// A screen run cancelled in the instant between its screen grant and its slot request
    /// stays cancelled: the slot request must not overwrite the exit with `.queued(.slot)`,
    /// which checked out a slot for a run nobody wanted and reported its end twice.
    func testCancelBetweenScreenGrantAndSlotRequestStaysCancelled() async throws {
        let r = try runner()
        let acquired = LeaseLog()
        r.acquireHook = { [unowned r] id in r.cancel(runID: id) }
        let lease = try checkout()
        let id = r.start(spec("echo must-not-run", screen: true),
                         owner: LeaseHolderOwner(controller: controllerID, session: "A")) {
            acquired.add(lease)
            return lease
        }
        let events = try await collect(r, id)
        XCTAssertEqual(events, [.exited(.signal(SIGINT))])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(r.phase(runID: id), .exited(.signal(SIGINT)))
        XCTAssertTrue(acquired.all.isEmpty, "no slot was taken for the cancelled run")
    }

    /// A finished run whose spool the day-old prune deleted is forgotten with it, so `logs`
    /// says the run is gone instead of replaying an empty run as if it had printed nothing.
    func testPrunedSpoolRetiresItsRun() async throws {
        let root = try tempDir("runs")
        let r = Runner(runsRoot: root, shell: "/bin/sh", hostEnvironment: hostEnv, console: FixedConsole(state: consoleAvailable))
        let id = start(r, spec("echo hi"), try checkout())
        _ = try await collect(r, id)
        let dir = root.appendingPathComponent(id)
        let old = Date().addingTimeInterval(-25 * 3600)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        r.pruneOldSpools()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(r.phase(runID: id))
        XCTAssertNil(r.owner(runID: id))
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        init(limit: Int) { left = limit }
        func take() -> Bool { lock.withLock { left > 0 ? { left -= 1; return true }() : false } }
    }

    // MARK: - Power

    func testEveryRunHoldsIdleSleepUntilItEnds() async throws {
        let power = RecordingPower()
        let r = try runner(power: power)
        let events = try await collect(r, start(r, spec("echo hi"), try checkout()))
        XCTAssertEqual(exit(events), .code(0))
        XCTAssertEqual(power.everHeld, [.idleSleep])
        XCTAssertEqual(power.held, [])
    }

    // MARK: - Helpers

    private final class LeaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var leases: [CheckoutLease] = []
        private var lines: [String] = []
        func add(_ lease: CheckoutLease) { lock.withLock { leases.append(lease) } }
        func note(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [CheckoutLease] { lock.withLock { leases } }
        var notes: [String] { lock.withLock { lines } }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for w in waiters { w.resume() }
            waiters = []
        }
    }
}
