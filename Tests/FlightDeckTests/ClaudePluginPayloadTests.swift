import XCTest
@testable import FlightDeck

/// Guards the shipped plugin payload. It is data, not code, so nothing else would
/// catch a malformed manifest until a live session silently reported nothing.
final class ClaudePluginPayloadTests: XCTestCase {
    private func pluginRoot() throws -> URL {
        let url = Bundle(for: Self.self).url(forResource: "ClaudePlugin", withExtension: nil)
        return try XCTUnwrap(url, "ClaudePlugin must be bundled as a folder reference")
    }

    func testHooksManifestNamesExactlyTheSevenWiredEvents() throws {
        let url = try pluginRoot().appendingPathComponent("hooks/hooks.json")
        let data = try Data(contentsOf: url)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(hooks.keys),
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
             "Stop", "SessionEnd"],
            "PermissionRequest is wired record-only, to attribute a dialog to an agent and call; "
                + "it has no observable clear, so it never drives readiness. Notification fires "
                + "for permission prompts too and must stay unwired."
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

    // MARK: - The chain from a hook payload to a decoded record

    /// **The happy path, end to end, which nothing exercised before: a realistic
    /// pretty-printed payload in, one `HookEventRecord` out.**
    ///
    /// The script's whole body is `cat | tr -d '\n'` composed with `printf '%s\n'`, and that
    /// composition is the only link in the chain between claude and `ComposerReadiness` that
    /// no test covered — the recorder was run only with the variable *unset*, which exits
    /// before reaching any of it. Claude Code pretty-prints its hook payloads, so the newline
    /// strip is load-bearing: one unstripped payload writes six lines, five of which decode to
    /// nothing and one of which corrupts the line after it.
    func testARealisticPayloadRoundTripsIntoADecodableRecord() throws {
        let session = UUID()
        let payload = """
            {
              "session_id": "\(session.uuidString)",
              "transcript_path": "/Users/x/.claude/projects/-Users-x-repo/\(session.uuidString).jsonl",
              "cwd": "/Users/x/repo",
              "hook_event_name": "PostToolUse",
              "tool_name": "Bash",
              "tool_input": {
                "command": "echo hi",
                "description": "Say hi"
              }
            }
            """

        let directory = try run(record: payload, pluginRoot: try pluginRoot())

        let lines = try String(contentsOf: directory.appendingPathComponent("events.ndjson"),
                               encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "a pretty-printed payload must land as exactly one line")
        let record = try XCTUnwrap(HookEventRecord.decode(String(lines[0])),
                                   "the decoder must accept what the script actually writes")
        XCTAssertEqual(record.sessionID, session)
        XCTAssertEqual(record.event, "PostToolUse")
        XCTAssertEqual(ComposerReadiness.applying(record.event, to: .unknown), .live)
    }

    /// **Every hook command in the shipped manifest, run from a plugin root with a space in
    /// it — which in production is every installation there is.**
    ///
    /// `${CLAUDE_PLUGIN_ROOT}` expands to
    /// `/Applications/Flight Deck.app/Contents/Resources/ClaudePlugin`, and Claude Code runs a
    /// hook command through a shell. Unquoted, that word-splits at `Flight` and every hook
    /// dies with 127 — a total, silent failure of the claude half of the feature, on a path no
    /// amount of manifest *parsing* would have caught.
    ///
    /// The placeholder is substituted textually here, the way Claude Code substitutes it, and
    /// the result is handed to `bash -c`: that reproduces the real failure whether the
    /// expansion happens in Claude Code or in the shell, because the quoting is what saves it
    /// either way.
    func testEveryHookCommandSurvivesAPluginPathWithASpace() throws {
        let spaced = try stage(pluginInto: "Flight Deck.app")
        let data = try Data(contentsOf: spaced.appendingPathComponent("hooks/hooks.json"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])

        var commands: [String] = []
        for (_, value) in hooks {
            for matcher in (value as? [[String: Any]] ?? []) {
                for hook in (matcher["hooks"] as? [[String: Any]] ?? []) {
                    commands.append(try XCTUnwrap(hook["command"] as? String))
                }
            }
        }
        XCTAssertEqual(commands.count, 7, "the premise: seven wired events, seven commands")

        let session = UUID()
        for command in commands {
            let directory = try run(
                shell: command.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: spaced.path),
                payload: #"{"session_id":"\#(session.uuidString)","hook_event_name":"Stop"}"#,
                pluginRoot: spaced
            )
            let log = directory.appendingPathComponent("events.ndjson")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: log.path),
                "`\(command)` wrote nothing — an unquoted plugin root splits at the space"
            )
        }
    }

    // MARK: - Helpers

    /// A copy of the bundled plugin under a directory whose name contains a space, so a test
    /// can reproduce what `/Applications/Flight Deck.app` does to an unquoted expansion.
    private func stage(pluginInto name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plugin-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: try pluginRoot(), to: root)
        staged.append(root.deletingLastPathComponent())
        return root
    }

    /// Runs `scripts/record.sh` directly. Returns the event directory it was pointed at.
    private func run(record payload: String, pluginRoot: URL) throws -> URL {
        try run(
            shell: "\"\(pluginRoot.path)/scripts/record.sh\"", payload: payload,
            pluginRoot: pluginRoot
        )
    }

    /// Runs `command` through `bash -c` with the hook environment claude sets, feeding
    /// `payload` on stdin. Returns the `FLIGHT_DECK_EVENT_DIR` it created for the run.
    @discardableResult
    private func run(shell command: String, payload: String, pluginRoot: URL) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        staged.append(directory)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CLAUDE_PLUGIN_ROOT": pluginRoot.path,
            "FLIGHT_DECK_EVENT_DIR": directory.path,
        ]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       "a hook that exits non-zero blocks the agent: `\(command)`")
        return directory
    }

    private var staged: [URL] = []

    override func tearDownWithError() throws {
        for url in staged { try? FileManager.default.removeItem(at: url) }
        staged.removeAll()
    }
}
