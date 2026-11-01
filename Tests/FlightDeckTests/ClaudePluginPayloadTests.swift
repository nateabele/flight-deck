import XCTest
@testable import FlightDeck

/// Guards the shipped plugin payload. It is data, not code, so nothing else would
/// catch a malformed manifest until a live session silently reported nothing.
final class ClaudePluginPayloadTests: XCTestCase {
    private func pluginRoot() throws -> URL {
        let url = Bundle(for: Self.self).url(forResource: "ClaudePlugin", withExtension: nil)
        return try XCTUnwrap(url, "ClaudePlugin must be bundled as a folder reference")
    }

    /// The `flightdeck` CLI built beside this bundle: the bundle is
    /// `Flight Deck.app/Contents/PlugIns/FlightDeckTests.xctest`, and the app embeds the CLI in
    /// `Contents/MacOS`. `record.sh` hands every payload to its `hook-record`.
    private func cli() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacOS/flightdeck")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                      "the app must embed the flightdeck CLI at \(url.path)")
        return url
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

    /// **The happy path, end to end: a realistic pretty-printed payload in, one pared line
    /// out, and that line decodes.** Claude Code pretty-prints its hook payloads, so one
    /// payload must still land as exactly one line.
    ///
    /// **And the line keeps only what Flight Deck reads.** The payload's `cwd`,
    /// `transcript_path`, `tool_input` and `tool_response` are gone; the input survives only as
    /// the digest `DialogAttribution` compares, and it is the same digest a legacy raw line
    /// would have produced.
    func testARealisticPayloadIsParedToOneDecodableLine() throws {
        let session = UUID()
        let payload = """
            {
              "session_id": "\(session.uuidString)",
              "transcript_path": "/Users/x/.claude/projects/-Users-x-repo/\(session.uuidString).jsonl",
              "cwd": "/Users/x/repo",
              "hook_event_name": "PostToolUse",
              "tool_name": "Bash",
              "tool_use_id": "toolu_01",
              "tool_input": {
                "command": "echo hi",
                "description": "Say hi"
              },
              "tool_response": {"stdout": "secret output"}
            }
            """

        let directory = try run(record: payload, pluginRoot: try pluginRoot())

        let text = try String(contentsOf: directory.appendingPathComponent("events.ndjson"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "a pretty-printed payload must land as exactly one line")
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys),
                       ["session_id", "hook_event_name", "tool_name", "tool_use_id", "tool_input_digest"],
                       "only the fields Flight Deck reads")
        XCTAssertFalse(text.contains("secret output"), "tool output never reaches the log")
        XCTAssertFalse(text.contains("echo hi"), "tool input travels as a digest, not as text")

        let record = try XCTUnwrap(HookEventRecord.decode(String(lines[0])),
                                   "the decoder must accept what the recorder actually writes")
        XCTAssertEqual(record.sessionID, session)
        XCTAssertEqual(record.event, "PostToolUse")
        XCTAssertEqual(record.toolUseID, "toolu_01")
        XCTAssertEqual(ComposerReadiness.applying(record.event, to: .unknown), .live)
        let legacy = try XCTUnwrap(HookEventRecord.decode(
            #"{"session_id":"\#(session.uuidString)","hook_event_name":"PreToolUse","#
                + #""tool_input":{"description":"Say hi","command":"echo hi"}}"#))
        XCTAssertEqual(record.toolInput, legacy.toolInput,
                       "a pared line and a legacy raw line for the same input compare equal")
    }

    /// A prompt is the most personal thing a hook carries, and nothing reads it.
    func testAPromptsTextNeverReachesTheLog() throws {
        let session = UUID()
        let directory = try run(
            record: #"{"session_id":"\#(session.uuidString)","hook_event_name":"UserPromptSubmit","prompt":"my password is hunter2"}"#,
            pluginRoot: try pluginRoot())
        let text = try String(contentsOf: directory.appendingPathComponent("events.ndjson"), encoding: .utf8)
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertEqual(HookEventRecord.decode(text.trimmingCharacters(in: .newlines))?.event, "UserPromptSubmit")
        let mode = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("events.ndjson").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "the log is the owner's alone")
    }

    /// **A missing or older CLI must cost a hook nothing.** An older `flightdeck` has no
    /// `hook-record` and exits 2 on an unknown command — and exit 2 from a `PreToolUse` hook
    /// REFUSES the tool call. The recorder swallows it; the event is simply not recorded.
    func testAnOlderOrMissingCLINeverFailsTheHook() throws {
        let stubDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("old-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
        staged.append(stubDir)
        let old = stubDir.appendingPathComponent("flightdeck")
        try "#!/bin/bash\necho 'flightdeck: unknown command' >&2\nexit 2\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)

        let payload = #"{"session_id":"\#(UUID().uuidString)","hook_event_name":"PreToolUse"}"#
        for cliPath in [old.path, stubDir.appendingPathComponent("missing").path] {
            let directory = try run(
                shell: "\"\(try pluginRoot().path)/scripts/record.sh\"", payload: payload,
                pluginRoot: try pluginRoot(), cliPath: cliPath)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.ndjson").path),
                "nothing recorded, and above all nothing raw")
        }
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
    private func run(shell command: String, payload: String, pluginRoot: URL,
                     cliPath: String? = nil) throws -> URL {
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
            "FLIGHTDECK_CLI": try cliPath ?? cli().path,
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

    /// The usage mod is gone: the status line replaced it (`ClaudeStatusLine`). The one module the
    /// manifest names is `/switch-account`'s, and it must be a file that ships: a stale `modules`
    /// entry would make claude load a file that no longer ships, and a mod the engine switched
    /// off would blank every claude meter with nothing here to notice.
    func testHooksManifestLoadsOnlyTheEntryModuleAndTheStatusLineShips() throws {
        let root = try pluginRoot()
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("hooks/hooks.json"))) as? [String: Any])
        // One module: a module hooks `session.start` once, so flight-deck.tsx registers every command.
        XCTAssertEqual(obj["modules"] as? [String], ["./flight-deck.tsx"])
        for module in ["flight-deck.tsx", "switch-account.tsx", "budget.tsx", "cli.ts"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks/\(module)").path), module)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks/register.ts").path))
        let script = try String(contentsOf: root.appendingPathComponent(ClaudeStatusLine.scriptPath), encoding: .utf8)
        XCTAssertTrue(script.contains("FLIGHT_DECK_USAGE_DIR"))
        XCTAssertTrue(script.contains(ClaudeStatusLine.userCommandVariable))
    }

    override func tearDownWithError() throws {
        for url in staged { try? FileManager.default.removeItem(at: url) }
        staged.removeAll()
    }
}
