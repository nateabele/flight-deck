import XCTest
@testable import FlightDeck

final class FlywheelProjectProbeTests: XCTestCase {
    private var made: [URL] = []
    override func tearDown() { made.forEach { try? FileManager.default.removeItem(at: $0) }; made = [] }

    private func tempRepo(_ build: (URL) throws -> Void) rethrows -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fw-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        made.append(dir); try build(dir); return dir
    }
    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testNoMarkers() throws {
        let s = FlywheelProjectProbe.status(of: try tempRepo { _ in })
        XCTAssertFalse(s.isFlywheelProject)
        XCTAssertFalse(s.needsSetup)
    }

    func testBeadsAndAgentMailDetectedNeedsSetup() throws {
        let repo = try tempRepo { dir in
            try mkdir(dir.appendingPathComponent(".beads"))
            try Data().write(to: dir.appendingPathComponent(".agent-mail.yaml"))
        }
        let s = FlywheelProjectProbe.status(of: repo)
        XCTAssertTrue(s.hasBeads); XCTAssertTrue(s.hasAgentMailMarker)
        XCTAssertTrue(s.isFlywheelProject)
        XCTAssertFalse(s.guardInstalled); XCTAssertFalse(s.beadsSyncHooksInstalled)
        XCTAssertTrue(s.needsSetup)
    }

    func testGuardAndSyncDetectedViaHookContents() throws {
        let repo = try tempRepo { dir in
            try mkdir(dir.appendingPathComponent(".beads"))
            let hooks = dir.appendingPathComponent(".git/hooks")
            try mkdir(hooks)
            try "run hooks.d/pre-commit/50-agent-mail.py; br sync --flush-only\n"
                .write(to: hooks.appendingPathComponent("pre-commit"), atomically: true, encoding: .utf8)
        }
        let s = FlywheelProjectProbe.status(of: repo)
        XCTAssertTrue(s.guardInstalled)
        XCTAssertTrue(s.beadsSyncHooksInstalled)
        XCTAssertFalse(s.needsSetup) // fully set up
    }

    func testBeadsFileNotDirIsNotBeads() throws {
        let repo = try tempRepo { dir in
            try Data().write(to: dir.appendingPathComponent(".beads")) // a FILE, not a dir
        }
        XCTAssertFalse(FlywheelProjectProbe.status(of: repo).hasBeads)
    }
}
