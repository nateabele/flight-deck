import XCTest
@testable import FlightDeck

final class CodexPreferencesTests: XCTestCase {
    func testStoredSettingsReachCodexConfig() throws {
        let data = Data(#"{"addDirs":[],"reasoningEffort":"high","reasoningSummary":"detailed","verbosity":"low","webSearch":"live","networkAccess":false,"developerInstructions":"Review carefully","modelInstructionsFile":"/tmp/instructions.md"}"#.utf8)
        let options = try JSONDecoder().decode(CodexThreadOptions.self, from: data)
        let config = try XCTUnwrap(options.asThreadStartParams(cwd: "/tmp", historyMode: nil)["config"] as? [String: Any])
        XCTAssertEqual(config["model_reasoning_effort"] as? String, "high")
        XCTAssertEqual(config["model_reasoning_summary"] as? String, "detailed")
        XCTAssertEqual(config["model_verbosity"] as? String, "low")
        XCTAssertEqual(config["web_search"] as? String, "live")
        XCTAssertEqual(config["developer_instructions"] as? String, "Review carefully")
        XCTAssertEqual(config["model_instructions_file"] as? String, "/tmp/instructions.md")
        XCTAssertEqual((config["sandbox_workspace_write"] as? [String: Any])?["network_access"] as? Bool, false)
    }

    func testOldPreferencesKeepCodexDefaults() throws {
        let options = try JSONDecoder().decode(CodexThreadOptions.self, from: Data(#"{"addDirs":[]}"#.utf8))
        XCTAssertEqual(options, CodexThreadOptions())
        XCTAssertNil(options.asThreadStartParams(cwd: "/tmp", historyMode: nil)["config"])
        XCTAssertTrue(options.launchArguments.isEmpty)
    }

    func testProjectOverridesInheritAndPreserveExplicitNetworkDenial() {
        let global = CodexThreadOptions(reasoningEffort: "high", reasoningSummary: "detailed",
            verbosity: "high", webSearch: "cached", networkAccess: true,
            developerInstructions: "Global instructions", modelInstructionsFile: "/global.md")
        XCTAssertEqual(CodexThreadOptions.merge(global: global, project: CodexThreadOptions()), global)
        let merged = CodexThreadOptions.merge(global: global,
            project: CodexThreadOptions(verbosity: "low", webSearch: "live", networkAccess: false))
        XCTAssertEqual(merged.networkAccess, false)
        XCTAssertEqual(merged.verbosity, "low")
        XCTAssertEqual(merged.webSearch, "live")
        XCTAssertEqual(merged.developerInstructions, global.developerInstructions)
    }

    func testResumeArgumentsPreservePromptTextThroughTheShell() throws {
        let instructions = "It's $(printf injected); `echo bad`\n\"quoted\" \\ path"
        let options = CodexThreadOptions(model: "custom model", sandbox: "workspace-write",
            approvalPolicy: "on-request", addDirs: ["/tmp/extra dir"], reasoningEffort: "high",
            networkAccess: false, developerInstructions: instructions)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\0' " + options.launchArguments.joined(separator: " ")]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let args = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        XCTAssertEqual(Array(args.prefix(4)), ["--model", "custom model", "--sandbox", "workspace-write"])
        let value = try XCTUnwrap(args.first { $0.hasPrefix("developer_instructions=") })
        let literal = String(value.dropFirst("developer_instructions=".count))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(literal.utf8)), instructions)
        XCTAssertTrue(args.contains("sandbox_workspace_write.network_access=false"))
        XCTAssertTrue(args.contains(#"sandbox_workspace_write.writable_roots=["/tmp/extra dir"]"#))
    }
}
