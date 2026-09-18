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
        let hook = try String(contentsOf: r.appendingPathComponent(".git/hooks/pre-commit"), encoding: .utf8)
        XCTAssertTrue(hook.contains("br sync"))
    }

    func testGuardInstallNonZeroThrows() async {
        let r = repo { _ in }
        let fake = FakeRunner(); fake.exitCode = 1
        await XCTAssertThrowsErrorAsync(try await FlywheelSetup(runner: fake, amPath: "am").enable(repo: r))
    }
}
