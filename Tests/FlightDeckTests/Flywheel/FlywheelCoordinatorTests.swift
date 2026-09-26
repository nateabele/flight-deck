import XCTest
@testable import FlightDeck

private final class FakeRunner: FlywheelProcessRunner, @unchecked Sendable {
    var stdout: String
    var exitCode: Int32
    private(set) var argv: [[String]] = []
    init(stdout: String, exitCode: Int32 = 0) { self.stdout = stdout; self.exitCode = exitCode }
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        argv.append([exe] + args); return (stdout, exitCode)
    }
}

final class FlywheelCoordinatorTests: XCTestCase {
    private let json = #"{"agent":{"name":"BlueFalcon"},"inbox":[]}"#

    func testBootBuildsStartSessionArgvAndParsesName() async throws {
        let fake = FakeRunner(stdout: json)
        let c = FlywheelCoordinator(runner: fake, amPath: "/usr/local/bin/am")
        let id = try await c.boot(project: "/tmp/p", program: "claude-code", model: "opus-4.8", name: nil)
        XCTAssertEqual(id.agentName, "BlueFalcon")
        XCTAssertEqual(id.project, "/tmp/p")
        XCTAssertEqual(fake.argv.first, [
            "/usr/local/bin/am", "macros", "start-session",
            "--project", "/tmp/p", "--program", "claude-code", "--model", "opus-4.8", "--json",
        ])
    }

    func testBootPassesNameBeforeJsonFlag() async throws {
        let fake = FakeRunner(stdout: json)
        _ = try await FlywheelCoordinator(runner: fake, amPath: "am")
            .boot(project: "/tmp/p", program: "codex-cli", model: "gpt-5", name: "BlueFalcon")
        let argv = try XCTUnwrap(fake.argv.first)
        XCTAssertEqual(argv.suffix(3), ["-n", "BlueFalcon", "--json"])
    }

    func testEnvironmentDelta() {
        let env = FlywheelIdentity(agentName: "RedOtter", project: "/tmp/p").environment
        XCTAssertEqual(env["AGENT_NAME"], "RedOtter")
        XCTAssertEqual(env["AGENT_MAIL_AGENT"], "RedOtter")
        XCTAssertEqual(env["AGENT_MAIL_PROJECT"], "/tmp/p")
        XCTAssertEqual(env.count, 3)
    }

    func testProgramMapping() {
        XCTAssertEqual(FlywheelProgram.rawValue(for: .claude), "claude-code")
        XCTAssertEqual(FlywheelProgram.rawValue(for: .codex), "codex-cli")
    }

    func testNonZeroExitThrows() async {
        let fake = FakeRunner(stdout: "", exitCode: 1)
        await XCTAssertThrowsErrorAsync(try await FlywheelCoordinator(runner: fake, amPath: "am")
            .boot(project: "/tmp/p", program: "claude-code", model: "m", name: nil))
    }

    func testUnparseableStdoutThrows() async {
        let fake = FakeRunner(stdout: "not json")
        await XCTAssertThrowsErrorAsync(try await FlywheelCoordinator(runner: fake, amPath: "am")
            .boot(project: "/tmp/p", program: "claude-code", model: "m", name: nil))
    }
}

// Small async-throwing helper if the suite lacks one. If an equivalent already exists
// in the test target, delete this and use that instead (search for "ThrowsErrorAsync").
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do { _ = try await expression(); XCTFail("expected error", file: file, line: line) }
    catch {}
}
