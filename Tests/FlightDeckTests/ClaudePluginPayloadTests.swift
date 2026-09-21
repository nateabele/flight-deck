import XCTest
@testable import FlightDeck

/// Guards the shipped plugin payload. It is data, not code, so nothing else would
/// catch a malformed manifest until a live session silently reported nothing.
final class ClaudePluginPayloadTests: XCTestCase {
    private func pluginRoot() throws -> URL {
        let url = Bundle(for: Self.self).url(forResource: "ClaudePlugin", withExtension: nil)
        return try XCTUnwrap(url, "ClaudePlugin must be bundled as a folder reference")
    }

    func testHooksManifestNamesExactlyTheSixLifecycleEvents() throws {
        let url = try pluginRoot().appendingPathComponent("hooks/hooks.json")
        let data = try Data(contentsOf: url)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(hooks.keys),
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"],
            "PermissionRequest has no observable clear and Notification fires for permission "
                + "prompts too — see the spec. Neither may be wired."
        )
    }

    func testRecorderScriptIsExecutable() throws {
        let url = try pluginRoot().appendingPathComponent("scripts/record.sh")
        let perms = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((try XCTUnwrap(perms).intValue) & 0o111, 0o111, "must survive bundling +x")
    }

    func testRecorderIsSilentWithoutTheEnvironmentVariable() throws {
        let script = try pluginRoot().appendingPathComponent("scripts/record.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"x"}"#.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "a failing hook blocks the agent")
    }
}
