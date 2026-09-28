import XCTest
import IntakeKit

/// `ActivityParser` folds a harness's live stream into the one `SeatActivity` a seat's row
/// shows. Every assertion here is about a signal the agents REALLY emit — the fold over the
/// two captured samples (a live codex drafter/integrator, a live `claude -p` stream-json run)
/// is what pins that, and the synthetic lines only cover event kinds those samples happen not
/// to contain (codex `reasoning`/`todo_list`/`web_search`, claude `TodoWrite`, readable
/// thinking), shaped exactly as the controller's probe recorded them.
final class ActivityParserTests: XCTestCase {
    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jsonl",
                                                                       subdirectory: "Fixtures/Intake")))
    }

    /// A clock the test moves by hand.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    }

    private let project = URL(fileURLWithPath: "/p/proj")

    private func parser(_ h: Harness, cwd: URL? = nil, clock: Clock = Clock()) -> ActivityParser {
        ActivityParser(harness: h, project: project, cwd: cwd, now: { clock.now })
    }

    private func line(_ obj: [String: Any]) -> Data {
        var d = try! JSONSerialization.data(withJSONObject: obj)
        d.append(0x0A)
        return d
    }
    private func claudeTool(_ name: String, _ input: [String: Any], id: String = "m1") -> Data {
        line(["type": "assistant", "message": ["id": id, "content": [["type": "tool_use", "name": name, "input": input]]]])
    }
    private func codexCommand(_ command: String) -> Data {
        line(["type": "item.started", "item": ["type": "command_execution", "command": command, "status": "in_progress"]])
    }

    // MARK: - Real samples

    func testFoldsTheLiveCodexDrafterSample() throws {
        let clock = Clock()
        var p = ActivityParser(harness: .codex, project: URL(fileURLWithPath: "/Users/nate/tallyho"), now: { clock.now })
        p.feed(try load("codex-stream-activity"))
        let a = p.activity
        // The last tool the drafter ran: `rg --files … | sort && find …`, unwrapped from codex's
        // `/bin/zsh -lc "…"` and read as a listing, not "Running /bin/zsh".
        XCTAssertEqual(a.action, ActivityAction(verb: "Listing", object: nil))
        // `sed -n '1,240p' README.md` with cwd = the project: one file, at the project's top level.
        XCTAssertEqual(a.footprint, [".": 1])
        XCTAssertEqual(a.inputTokens, 86949)
        XCTAssertEqual(a.outputTokens, 3589)
        XCTAssertNil(a.headline, "this sample carries no reasoning item")
        XCTAssertNil(a.costUSD, "codex reports no cost")
        XCTAssertTrue(a.finished)
        XCTAssertNil(a.error)
        XCTAssertEqual(a.lastEventAt, clock.now)
    }

    /// The integrator runs with cwd = the intake's work dir, OUTSIDE the project: its relative
    /// `sed -n … changes.json` and its absolute `file_change` on plan.md both land under the
    /// work dir's own name, counted once per distinct file however many times it was touched.
    func testFoldsTheLiveCodexIntegratorSample() throws {
        let work = URL(fileURLWithPath: "/Users/nate/.fd-rounds-live-34E65942-D920-48BB-BF63-B954AE84CC27/intakes/8570E1D1-1E05-4E32-A3BA-AFB4781D0C08/work")
        var p = ActivityParser(harness: .codex, project: URL(fileURLWithPath: "/Users/nate/tallyho"), cwd: work,
                               now: { Date(timeIntervalSince1970: 0) })
        p.feed(try load("codex-stream-integrator"))
        XCTAssertEqual(p.activity.footprint, ["work": 2])
        XCTAssertEqual(p.activity.action, ActivityAction(verb: "Editing", object: work.appendingPathComponent("plan.md").path))
        XCTAssertEqual(p.activity.inputTokens, 129861)
        XCTAssertEqual(p.activity.outputTokens, 5173)
    }

    func testFoldsTheLiveClaudeSample() throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-flight-deck/9bf1e259-cc02-4f83-884e-27183594e064/scratchpad/cprobe")
        var p = ActivityParser(harness: .claude, project: root, now: { Date(timeIntervalSince1970: 0) })
        p.feed(try load("claude-stream-activity"))
        let a = p.activity
        XCTAssertEqual(a.action, ActivityAction(verb: "Searching", object: "\"hello\""))
        XCTAssertEqual(a.footprint, [".": 1], "Read a.txt at the project root")
        // The final `result`'s totals win over the per-message running sum: input counts the
        // cache reads and writes too, since that is what the model actually processed.
        XCTAssertEqual(a.inputTokens, 26 + 18912 + 9394)
        XCTAssertEqual(a.outputTokens, 406)
        XCTAssertEqual(a.costUSD, 0.0408194)
        XCTAssertNil(a.rateLimitedAt, "a rate_limit_event whose status is `allowed` is not a limit")
        XCTAssertNil(a.headline, "haiku's thinking blocks arrive empty")
        XCTAssertTrue(a.finished)
        XCTAssertNil(a.error)
    }

    // MARK: - Headline

    func testCodexReasoningHeadlineIsTheFirstSentenceWithoutBold() {
        var p = parser(.codex)
        p.feed(line(["type": "item.completed", "item": ["type": "reasoning",
                     "text": "**Inspecting the CLI entry point**\n\nI need to find where commands dispatch."]]))
        XCTAssertEqual(p.activity.headline, "Inspecting the CLI entry point")
        p.feed(line(["type": "item.completed", "item": ["type": "reasoning",
                     "text": "Checking **tests** first. Then the rest."]]))
        XCTAssertEqual(p.activity.headline, "Checking tests first.")
    }

    func testClaudeThinkingHeadlineIsCappedNearNinetyCharacters() throws {
        var p = parser(.claude)
        let long = String(repeating: "word ", count: 40)
        p.feed(line(["type": "assistant", "message": ["id": "m", "content": [["type": "thinking", "thinking": long]]]]))
        let h = try XCTUnwrap(p.activity.headline)
        XCTAssertLessThanOrEqual(h.count, 90)
        XCTAssertTrue(h.hasSuffix("…"), h)
        // An empty thinking block (redacted) never blanks a headline that was already there.
        p.feed(line(["type": "assistant", "message": ["id": "m2", "content": [["type": "thinking", "thinking": ""]]]]))
        XCTAssertEqual(p.activity.headline, h)
    }

    // MARK: - Verb mapping

    func testToolAndCommandVerbTable() {
        let cases: [(Data, ActivityAction)] = [
            (claudeTool("Read", ["file_path": "/p/proj/Sources/App/main.swift"]), .init(verb: "Reading", object: "Sources/App/main.swift")),
            (claudeTool("Read", ["file_path": "/elsewhere/notes.md"]), .init(verb: "Reading", object: "/elsewhere/notes.md")),
            (claudeTool("Grep", ["pattern": "func run", "path": "/p/proj"]), .init(verb: "Searching", object: "\"func run\"")),
            (claudeTool("Glob", ["pattern": "**/*.swift"]), .init(verb: "Listing", object: "**/*.swift")),
            (claudeTool("Edit", ["file_path": "/p/proj/a.swift"]), .init(verb: "Editing", object: "a.swift")),
            (claudeTool("Write", ["file_path": "/p/proj/b/c.md"]), .init(verb: "Editing", object: "b/c.md")),
            (claudeTool("WebSearch", ["query": "swift actors"]), .init(verb: "Searching the web", object: "swift actors")),
            (claudeTool("mcp__qartez__qartez_map", [:]), .init(verb: "Using", object: "qartez_map")),
            (claudeTool("Bash", ["command": "cat README.md"]), .init(verb: "Reading", object: "README.md")),
            (claudeTool("Bash", ["command": "head -n 50 Sources/x.swift"]), .init(verb: "Reading", object: "Sources/x.swift")),
            (claudeTool("Bash", ["command": "rg -n 'TODO' Sources"]), .init(verb: "Searching", object: "\"TODO\"")),
            (claudeTool("Bash", ["command": "grep -rn -e needle ."]), .init(verb: "Searching", object: "\"needle\"")),
            (claudeTool("Bash", ["command": "git log --oneline -8"]), .init(verb: "Running", object: "git log --oneline -8")),
            (claudeTool("Bash", ["command": "br list --json"]), .init(verb: "Running", object: "br list --json")),
            (claudeTool("Bash", ["command": "cd sub && swift build"]), .init(verb: "Running", object: "swift build")),
            (codexCommand(#"/bin/zsh -lc "sed -n '1,240p' README.md""#), .init(verb: "Reading", object: "README.md")),
            (codexCommand(#"/bin/zsh -lc "rg -n \"HarnessOutput\" Sources | head""#), .init(verb: "Searching", object: "\"HarnessOutput\"")),
            (codexCommand(#"/bin/zsh -lc 'git status --short'"#), .init(verb: "Running", object: "git status --short")),
            (codexCommand(#"/bin/zsh -lc "jq length changes.json""#), .init(verb: "Running", object: "jq length changes.json")),
            (line(["type": "item.started", "item": ["type": "file_change", "changes": [["path": "/p/proj/x/y.swift", "kind": "update"]]]]),
             .init(verb: "Editing", object: "x/y.swift")),
            (line(["type": "item.started", "item": ["type": "mcp_tool_call", "server": "qartez", "tool": "qartez_grep", "arguments": [:]]]),
             .init(verb: "Using", object: "qartez_grep")),
            (line(["type": "item.completed", "item": ["type": "web_search", "query": "codex exec json"]]),
             .init(verb: "Searching the web", object: "codex exec json")),
        ]
        for (event, expected) in cases {
            var p = parser(event.count > 0 && String(decoding: event, as: UTF8.self).contains("\"item\"") ? .codex : .claude)
            p.feed(event)
            XCTAssertEqual(p.activity.action, expected, String(decoding: event, as: UTF8.self))
        }
    }

    /// Footprint: distinct files by top-level directory relative to the project; a path
    /// outside the project goes under its own parent directory's name.
    func testFootprintCountsDistinctFilesByTopLevelDirectory() {
        var p = parser(.claude)
        for path in ["/p/proj/Sources/a.swift", "/p/proj/Sources/a.swift", "/p/proj/Sources/b/c.swift",
                     "/p/proj/Tests/t.swift", "/p/proj/README.md", "/tmp/scratch/notes.md", "/top.txt"] {
            p.feed(claudeTool("Read", ["file_path": path]))
        }
        p.feed(claudeTool("Bash", ["command": "sed -n '1,20p' Sources/a.swift"]))   // relative to cwd = project
        XCTAssertEqual(p.activity.footprint, ["Sources": 2, "Tests": 1, ".": 1, "scratch": 1, "other": 1])
    }

    // MARK: - Steps

    func testStepsFromCodexTodoListAndClaudeTodoWrite() {
        var codex = parser(.codex)
        codex.feed(line(["type": "item.updated", "item": ["type": "todo_list", "items": [
            ["text": "Read the CLI", "completed": true], ["text": "Draft the plan", "completed": false],
            ["text": "Check tests", "completed": false]]]]))
        XCTAssertEqual(codex.activity.steps, ActivitySteps(done: 1, total: 3, current: "Draft the plan"))

        var claude = parser(.claude)
        claude.feed(claudeTool("TodoWrite", ["todos": [
            ["content": "Read", "status": "completed", "activeForm": "Reading"],
            ["content": "Plan", "status": "in_progress", "activeForm": "Planning"],
            ["content": "Ship", "status": "pending", "activeForm": "Shipping"]]]))
        XCTAssertEqual(claude.activity.steps, ActivitySteps(done: 1, total: 3, current: "Planning"))
        XCTAssertNil(claude.activity.action, "TodoWrite is bookkeeping, not an action")
    }

    // MARK: - Rate limit, errors, garbage

    func testRateLimitIsSetByARejectingEventAndClearedByTheNextAssistantEvent() {
        let clock = Clock()
        var p = parser(.claude, clock: clock)
        p.feed(line(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed"]]))
        XCTAssertNil(p.activity.rateLimitedAt)
        clock.advance(5)
        p.feed(line(["type": "rate_limit_event", "rate_limit_info": ["status": "rejected", "resetsAt": 1_790_567_400]]))
        XCTAssertEqual(p.activity.rateLimitedAt, clock.now)
        p.feed(line(["type": "user", "message": ["content": [["type": "tool_result", "content": "x"]]]]))
        XCTAssertNotNil(p.activity.rateLimitedAt, "only the model speaking again clears it")
        clock.advance(30)
        p.feed(claudeTool("Read", ["file_path": "/p/proj/a"], id: "m9"))
        XCTAssertNil(p.activity.rateLimitedAt)
        XCTAssertEqual(p.activity.lastEventAt, clock.now)
    }

    func testGarbageAndPartialLinesAreToleratedAcrossChunks() {
        let clock = Clock()
        var p = parser(.codex, clock: clock)
        let before = p.activity
        p.feed(Data("not json at all\n[1,2]\n\n{\"type\":\n".utf8))
        XCTAssertEqual(p.activity, before, "garbage changes nothing, not even lastEventAt")
        // One event split across three chunks, the way a pipe hands it over.
        let event = codexCommand(#"/bin/zsh -lc "cat a.txt""#)
        p.feed(event.prefix(10)); p.feed(event.dropFirst(10).prefix(15))
        XCTAssertNil(p.activity.action, "no newline yet — nothing to fold")
        p.feed(event.dropFirst(25))
        XCTAssertEqual(p.activity.action, ActivityAction(verb: "Reading", object: "a.txt"))
    }

    func testErrorsAndFinish() {
        var claude = parser(.claude)
        claude.feed(line(["type": "result", "subtype": "success", "is_error": true, "result": "Invalid API key · Please run /login",
                          "total_cost_usd": 0]))
        XCTAssertEqual(claude.activity.error, "Invalid API key · Please run /login")
        XCTAssertTrue(claude.activity.finished)

        var codex = parser(.codex)
        codex.feed(line(["type": "turn.failed", "error": ["message": "stream disconnected"]]))
        XCTAssertEqual(codex.activity.error, "stream disconnected")

        var exited = parser(.codex)
        exited.feed(Data(#"{"type":"turn.started"}"#.utf8))   // a last line with no newline is still folded at exit
        exited.finish(exitCode: 3)
        XCTAssertTrue(exited.activity.finished)
        XCTAssertEqual(exited.activity.error, "exited 3")
        XCTAssertNotNil(exited.activity.lastEventAt)
    }

    func testActivityRoundTripsThroughJSON() throws {
        var p = parser(.claude)
        p.feed(claudeTool("Read", ["file_path": "/p/proj/Sources/a.swift"]))
        let data = try IntakeJSON.encoder.encode(p.activity)
        XCTAssertEqual(try IntakeJSON.decoder.decode(SeatActivity.self, from: data), p.activity)
    }
}

/// `ActivityPublisher` owns a seat's `activity.json`: written at start, then at most every
/// `interval` while events arrive, with a trailing write so the last event before a quiet
/// spell (a long `swift build`) is never left unpublished, and once more at finish.
final class ActivityPublisherTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    }
    /// Captures the trailing-flush timers instead of running them, so the test fires them.
    final class Timers: @unchecked Sendable {
        var pending: [(TimeInterval, @Sendable () -> Void)] = []
        func fire() { let p = pending; pending = []; p.forEach { $0.1() } }
    }

    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityPublisherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func read() throws -> SeatActivity {
        try IntakeJSON.decoder.decode(SeatActivity.self, from: Data(contentsOf: dir.appendingPathComponent("activity.json")))
    }
    private func read(_ path: String) -> Data {
        Data((#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","name":"Read","input":{"file_path":"\#(path)"}}]}}"# + "\n").utf8)
    }

    func testWritesAtStartThrottlesToTwoSecondsFlushesTrailingAndWritesAtFinish() throws {
        let clock = Clock(), timers = Timers()
        let pub = ActivityPublisher(harness: .claude, project: URL(fileURLWithPath: "/p"),
                                    destination: dir.appendingPathComponent("activity.json"), now: { clock.now },
                                    schedule: { delay, work in timers.pending.append((delay, work)) })
        pub.start()
        XCTAssertNil(try read().action, "start writes an empty activity at once")
        XCTAssertEqual(try read().startedAt, clock.now)

        clock.advance(0.5); pub.feed(read("/p/a"))
        XCTAssertNil(try read().action, "0.5s after the last write: held back")
        XCTAssertEqual(timers.pending.map(\.0), [1.5], "a trailing flush for the rest of the interval")
        clock.advance(0.5); pub.feed(read("/p/b"))
        XCTAssertNil(try read().action)
        XCTAssertEqual(timers.pending.count, 1, "one pending flush at a time")

        clock.advance(1.1); pub.feed(read("/p/c"))
        XCTAssertEqual(try read().action?.object, "c", "2.1s since the last write: written now")
        timers.fire()
        XCTAssertEqual(try read().action?.object, "c", "a flush with nothing new writes nothing different")

        clock.advance(0.2); pub.feed(read("/p/d"))
        XCTAssertEqual(try read().action?.object, "c")
        timers.fire()
        XCTAssertEqual(try read().action?.object, "d", "the trailing flush publishes the held-back event")

        clock.advance(0.1); pub.finish(exitCode: 0)
        let final = try read()
        XCTAssertTrue(final.finished)
        XCTAssertEqual(final.footprint, [".": 4])
        timers.fire()
        XCTAssertTrue(try read().finished, "a late flush never rewrites a finished activity")
    }

    func testFinishCarriesASpawnFailure() throws {
        let pub = ActivityPublisher(harness: .codex, project: URL(fileURLWithPath: "/p"),
                                    destination: dir.appendingPathComponent("activity.json"), now: { Date() })
        pub.start()
        pub.finish(exitCode: nil, error: "Could not run codex")
        XCTAssertEqual(try read().error, "Could not run codex")
        XCTAssertTrue(try read().finished)
    }
}
