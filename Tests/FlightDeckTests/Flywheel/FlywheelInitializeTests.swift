import XCTest
@testable import FlightDeck

/// `FlywheelSetup.initialize` — the "Setup Flywheel…" menu item's target for a plain repo
/// the probe found neither `.beads/` nor `.agent-mail.yaml` in. Unlike `FlywheelSetupTests`'
/// `FakeRunner`, this one simulates the filesystem side effects the real `br init` and
/// `am projects discovery-init` have (creating `.beads/` and `.agent-mail.yaml`
/// respectively) so the gating against `FlywheelProjectProbe` — and `enable`'s own steps
/// running afterward — can be exercised without a real `br`/`am` on `PATH`.
private final class SimulatingFakeRunner: FlywheelProcessRunner, @unchecked Sendable {
    var exitCode: Int32 = 0
    /// Which step (by argv prefix) should fail, if any — lets a test point the failure at a
    /// specific step and confirm nothing after it ran.
    var failingArgv: [String]?
    private(set) var argv: [[String]] = []

    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        let full = [exe] + args
        argv.append(full)

        if let failingArgv, full.starts(with: failingArgv) {
            return ("boom", 1)
        }

        guard let cwd else { return ("", exitCode) }
        if args.first == "init" {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: cwd).appendingPathComponent(".beads"), withIntermediateDirectories: true
            )
        }
        if args.first == "agents" {
            try? Data().write(to: URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.md"))
        }
        if args.first == "projects" {
            try? Data().write(to: URL(fileURLWithPath: cwd).appendingPathComponent(".agent-mail.yaml"))
        }
        return ("", exitCode)
    }
}

final class FlywheelInitializeTests: XCTestCase {
    private var made: [URL] = []
    override func tearDown() { made.forEach { try? FileManager.default.removeItem(at: $0) }; made = [] }

    /// A plain repo: real git hooks directory (so `enable`'s hook-install steps have
    /// somewhere to write), but no `.beads/` or `.agent-mail.yaml` — the state the probe
    /// reports as "not a flywheel project" and that routes the menu to "Setup Flywheel…".
    private func plainRepo() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fw-init-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        made.append(d)
        return d
    }

    func testBootstrapsPlainRepoThenRunsEnable() async throws {
        let repo = plainRepo()
        let fake = SimulatingFakeRunner()
        let setup = FlywheelSetup(runner: fake, amPath: "am", brPath: "br")

        let steps = try await setup.initialize(repo: repo)

        XCTAssertTrue(fake.argv.contains { $0.first == "br" && $0.dropFirst().first == "init" })
        XCTAssertTrue(fake.argv.contains { $0.first == "br" && $0.dropFirst().first == "agents" })
        XCTAssertTrue(fake.argv.contains { $0.first == "am" && $0.dropFirst().first == "projects" })
        XCTAssertTrue(fake.argv.contains { $0.first == "am" && $0.dropFirst().first == "guard" })

        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".git/hooks/hooks.d/pre-commit/60-beads-sync.sh").path
        ))

        XCTAssertTrue(steps.contains("beads workspace (br init)"))
        XCTAssertTrue(steps.contains("AGENTS.md (br agents --add)"))
        XCTAssertTrue(steps.contains("agent-mail marker (am projects discovery-init)"))
        XCTAssertTrue(steps.contains("am guard install"))
        XCTAssertTrue(steps.contains("beads sync hook"))
    }

    func testSkipsBootstrapWhenMarkersAlreadyPresent() async throws {
        let repo = plainRepo()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".beads"), withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent(".agent-mail.yaml"))
        // `br agents --add` is gated on its own marker (AGENTS.md's fence), not on `.beads/` —
        // without this the agents step would still fire even though the "already present" case
        // this test means to cover is every marker present, not just the two bootstrap files.
        try "before\n<!-- br-agent-instructions-v1 -->\nfenced\n<!-- end-br-agent-instructions -->\n"
            .write(to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let fake = SimulatingFakeRunner()
        let setup = FlywheelSetup(runner: fake, amPath: "am", brPath: "br")

        let steps = try await setup.initialize(repo: repo)

        XCTAssertFalse(fake.argv.contains { $0.first == "br" })
        XCTAssertFalse(fake.argv.contains { $0.dropFirst().first == "projects" })
        XCTAssertFalse(steps.contains { $0.contains("br init") || $0.contains("discovery-init") || $0.contains("AGENTS.md") })
        // `enable`'s own steps still ran — bootstrap being done doesn't mean guard/hook are.
        XCTAssertTrue(steps.contains("am guard install"))
    }

    /// A repo whose `.beads/` already exists (so `br init` is skipped) but whose `AGENTS.md`
    /// has no fenced section yet — the resume case Fix 1 exists for: `br agents --add` used to
    /// be gated on the same `!status.hasBeads` as `br init`, so once `.beads/` existed the
    /// agents step never ran again even if it had previously failed. It is gated on its own
    /// marker now, so it still fires here.
    func testAgentsStepRunsWhenBeadsExistsButAgentsSectionDoesNot() async throws {
        let repo = plainRepo()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".beads"), withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent(".agent-mail.yaml"))
        let fake = SimulatingFakeRunner()
        let setup = FlywheelSetup(runner: fake, amPath: "am", brPath: "br")

        let steps = try await setup.initialize(repo: repo)

        XCTAssertTrue(fake.argv.contains { $0.first == "br" && $0.dropFirst().first == "agents" })
        XCTAssertTrue(steps.contains("AGENTS.md (br agents --add)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("AGENTS.md").path))
    }

    /// The full resume scenario: `br init` succeeds, `br agents --add` fails (so `initialize`
    /// throws and `.beads/` is left behind), then a second `initialize` call — with a runner
    /// that now succeeds — must still invoke `br agents --add` rather than treating `.beads/`
    /// existing as proof the agents step already ran.
    func testReRunAfterAgentsStepFailureStillInvokesAgentsAdd() async throws {
        let repo = plainRepo()
        let firstRun = SimulatingFakeRunner()
        firstRun.failingArgv = ["br", "agents"]
        let firstSetup = FlywheelSetup(runner: firstRun, amPath: "am", brPath: "br")

        do {
            _ = try await firstSetup.initialize(repo: repo)
            XCTFail("expected the first run to throw")
        } catch let error as FlywheelError {
            guard case .initializeStep(let step, _, _) = error else {
                XCTFail("expected .initializeStep, got \(error)")
                return
            }
            XCTAssertEqual(step, "br agents --add")
        }

        // `.beads/` is on disk (br init succeeded) but AGENTS.md never got written, and
        // `enable`'s own steps never ran — the failure happened before `initialize` reached them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("AGENTS.md").path))
        XCTAssertFalse(firstRun.argv.contains { $0.first == "am" })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".git/hooks/hooks.d/pre-commit/60-beads-sync.sh").path
        ))

        let secondRun = SimulatingFakeRunner()
        let secondSetup = FlywheelSetup(runner: secondRun, amPath: "am", brPath: "br")

        _ = try await secondSetup.initialize(repo: repo)

        XCTAssertTrue(secondRun.argv.contains { $0.first == "br" && $0.dropFirst().first == "agents" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("AGENTS.md").path))
    }

    func testBrInitFailureThrowsAndSkipsLaterSteps() async {
        let repo = plainRepo()
        let fake = SimulatingFakeRunner()
        fake.failingArgv = ["br", "init"]
        let setup = FlywheelSetup(runner: fake, amPath: "am", brPath: "br")

        do {
            _ = try await setup.initialize(repo: repo)
            XCTFail("expected initialize to throw")
        } catch let error as FlywheelError {
            guard case .initializeStep(let step, _, _) = error else {
                XCTFail("expected .initializeStep, got \(error)")
                return
            }
            XCTAssertEqual(step, "br init")
        } catch {
            XCTFail("expected FlywheelError, got \(error)")
        }

        XCTAssertFalse(fake.argv.contains { $0.first == "am" })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".git/hooks/hooks.d/pre-commit/60-beads-sync.sh").path
        ))
    }

    /// A LATER step failing — `br init` and `br agents --add` both succeed, but `am projects
    /// discovery-init` does not — must surface just as cleanly as an early-step failure: the
    /// thrown error names that step specifically, and `enable`'s own steps (which run last,
    /// after the bootstrap) never start.
    func testAmProjectsDiscoveryInitFailureThrowsAndSkipsEnable() async {
        let repo = plainRepo()
        let fake = SimulatingFakeRunner()
        fake.failingArgv = ["am", "projects", "discovery-init"]
        let setup = FlywheelSetup(runner: fake, amPath: "am", brPath: "br")

        do {
            _ = try await setup.initialize(repo: repo)
            XCTFail("expected initialize to throw")
        } catch let error as FlywheelError {
            guard case .initializeStep(let step, _, _) = error else {
                XCTFail("expected .initializeStep, got \(error)")
                return
            }
            XCTAssertEqual(step, "am projects discovery-init")
        } catch {
            XCTFail("expected FlywheelError, got \(error)")
        }

        // The two bootstrap steps ahead of the failing one did run...
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("AGENTS.md").path))
        // ...but `enable` (am guard install, beads sync hook) never started.
        XCTAssertFalse(fake.argv.contains { $0.first == "am" && $0.dropFirst().first == "guard" })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".git/hooks/hooks.d/pre-commit/60-beads-sync.sh").path
        ))
    }
}
