import XCTest
import IntakeKit

final class ClaudeUserEnvTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeUserEnvTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func settings(_ text: String) throws { try Data(text.utf8).write(to: home.appendingPathComponent(".claude/settings.json")) }

    func testMergesSettingsEnvUnderTheExplicitEnvironment() throws {
        try settings(#"{"permissions":{"allow":["Bash(git add *)"]},"env":{"ANTHROPIC_BASE_URL":"http://localhost:8787","PATH":"/settings","MAX":8}}"#)
        let merged = ClaudeUserEnv.merged(into: ["PATH": "/usr/bin"], home: home)
        XCTAssertEqual(merged, ["PATH": "/usr/bin", "ANTHROPIC_BASE_URL": "http://localhost:8787", "MAX": "8"])
    }

    func testMissingFileMeansNoEnv() {
        XCTAssertEqual(ClaudeUserEnv.merged(into: ["A": "1"], home: home.appendingPathComponent("nowhere")), ["A": "1"])
    }

    func testMalformedFileOrEnvMeansNoEnv() throws {
        try settings("{not json")
        XCTAssertEqual(ClaudeUserEnv.merged(into: ["A": "1"], home: home), ["A": "1"])
        try settings(#"{"env":["ANTHROPIC_BASE_URL"]}"#)
        XCTAssertEqual(ClaudeUserEnv.merged(into: ["A": "1"], home: home), ["A": "1"])
    }
}
