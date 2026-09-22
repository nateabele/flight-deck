import XCTest
@testable import FlightDeck

private final class FakeRunner: FlywheelProcessRunner, @unchecked Sendable {
    var exitCode: Int32 = 0
    private(set) var argv: [[String]] = []
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        argv.append([exe] + args); return ("", exitCode)
    }
}

final class FlywheelSetupTests: XCTestCase {
    private var made: [URL] = []
    override func tearDown() { made.forEach { try? FileManager.default.removeItem(at: $0) }; made = [] }
    private func repo(_ build: (URL) throws -> Void) rethrows -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fw-setup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent(".beads"), withIntermediateDirectories: true)
        made.append(d); try build(d); return d
    }

    func testInstallsGuardWhenAbsent() async throws {
        let r = repo { _ in }               // .beads present, no guard hook
        let fake = FakeRunner()
        let steps = try await FlywheelSetup(runner: fake, amPath: "am").enable(repo: r)
        XCTAssertTrue(fake.argv.contains(["am", "guard", "install", r.path, r.path]))
        XCTAssertTrue(steps.contains("am guard install"))
    }

    func testSkipsGuardWhenPresent() async throws {
        let r = try repo { d in
            try "50-agent-mail\n".write(to: d.appendingPathComponent(".git/hooks/pre-commit"), atomically: true, encoding: .utf8)
        }
        let fake = FakeRunner()
        _ = try await FlywheelSetup(runner: fake, amPath: "am").enable(repo: r)
        XCTAssertFalse(fake.argv.contains { $0.contains("guard") })
    }

    func testWritesBeadsSyncHookWhenAbsent() async throws {
        let r = repo { _ in }
        _ = try await FlywheelSetup(runner: FakeRunner(), amPath: "am").enable(repo: r)
        let scriptURL = r.appendingPathComponent(".git/hooks/hooks.d/pre-commit/60-beads-sync.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("br sync"))
        let perms = try FileManager.default.attributesOfItem(atPath: scriptURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms.map { $0 & 0o755 }, 0o755)
    }

    func testGuardInstallNonZeroThrows() async {
        let r = repo { _ in }
        let fake = FakeRunner(); fake.exitCode = 1
        await XCTAssertThrowsErrorAsync(try await FlywheelSetup(runner: fake, amPath: "am").enable(repo: r))
    }

    /// Regression: `am guard install` writes `pre-commit` as a Python chain-runner
    /// (`#!/usr/bin/env python3 ... sys.exit(first_failure)`). Appending shell lines to it
    /// used to be a `SyntaxError` that failed every commit. Beads-sync must land as its own
    /// script under `hooks.d/pre-commit/` and never touch `pre-commit` at all.
    func testPythonChainRunnerPreCommitIsUntouched() async throws {
        let pythonChainRunner = """
        #!/usr/bin/env python3
        import sys
        first_failure = 0
        sys.exit(first_failure)
        """
        let r = try repo { d in
            try pythonChainRunner.write(to: d.appendingPathComponent(".git/hooks/pre-commit"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: d.appendingPathComponent(".git/hooks/hooks.d/pre-commit"), withIntermediateDirectories: true
            )
        }
        let preCommitURL = r.appendingPathComponent(".git/hooks/pre-commit")
        let before = try Data(contentsOf: preCommitURL)

        _ = try await FlywheelSetup(runner: FakeRunner(), amPath: "am").enable(repo: r)

        let scriptURL = r.appendingPathComponent(".git/hooks/hooks.d/pre-commit/60-beads-sync.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("br sync"))
        let perms = try FileManager.default.attributesOfItem(atPath: scriptURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms.map { $0 & 0o755 }, 0o755)

        let after = try Data(contentsOf: preCommitURL)
        XCTAssertEqual(before, after, "pre-commit must be byte-for-byte unchanged")

        let py3 = Process()
        py3.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        py3.arguments = ["python3", "-m", "py_compile", preCommitURL.path]
        try py3.run()
        py3.waitUntilExit()
        XCTAssertEqual(py3.terminationStatus, 0, "pre-commit must still parse as valid Python")
    }
}
