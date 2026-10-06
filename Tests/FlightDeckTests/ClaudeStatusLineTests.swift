import XCTest
import IntakeKit
@testable import FlightDeck

/// The claude status line is two jobs in one command — the usage meter's only source for an
/// interactive tab, and the user's own status line — and a failure of either is silent: a
/// meter that reads "no reading", or a status line that looks different. These pin both.
final class ClaudeStatusLineTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    /// Under a folder with a space, like "Application Support/Flight Deck", so the quoting the
    /// launch line relies on is exercised, not assumed.
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("fd statusline \(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private static let tab = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private static let session = "8552adc8-bbae-48c2-9b86-29a5becfa369"

    /// Synthetic, in the shape claude 2.1.292 documents for a status line's stdin.
    private static func payload(fiveHour: Double = 82.5, input: Int = 1200, rateLimits: Bool = true) -> String {
        let limits = rateLimits ? #","rate_limits":{"five_hour":{"used_percentage":\#(fiveHour),"resets_at":1791000000},"seven_day":{"used_percentage":31,"resets_at":1791500000}}"# : ""
        return #"{"session_id":"\#(session)","cwd":"/tmp/x","model":{"id":"m","display_name":"Model"},"context_window":{"used_percentage":12,"current_usage":{"input_tokens":\#(input),"output_tokens":3}}\#(limits)}"# + "\n"
    }

    private func pluginRoot() throws -> URL {
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ClaudePlugin", withExtension: nil))
        let copy = root.appendingPathComponent("plugin", isDirectory: true)
        if !fm.fileExists(atPath: copy.path) { try fm.copyItem(at: bundled, to: copy) }
        return copy
    }

    private struct Run { var stdout: String; var status: Int32; var seconds: Double }

    /// Runs the wrapper the way claude does: its settings `command` string, through a shell.
    private func runWrapper(_ payload: String, env: [String: String]) throws -> Run {
        let wrapper = try pluginRoot().appendingPathComponent(ClaudeStatusLine.scriptPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", ClaudeSession.shellQuoted(wrapper.path)]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path].merging(env) { $1 }
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        let start = Date()
        try p.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(stdout: String(decoding: data, as: UTF8.self), status: p.terminationStatus, seconds: Date().timeIntervalSince(start))
    }

    private func usageDir() throws -> URL {
        let dir = root.appendingPathComponent("usage", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The wrapper script

    func testTheWrapperIsExecutable() throws {
        let perms = try fm.attributesOfItem(atPath: try pluginRoot().appendingPathComponent(ClaudeStatusLine.scriptPath).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((try XCTUnwrap(perms).intValue) & 0o111, 0o111, "must survive bundling +x")
    }

    func testTheWrapperWritesTheTabsUsageAndPassesTheUsersStatusLineThrough() throws {
        let dir = try usageDir()
        let seen = root.appendingPathComponent("seen stdin")
        let payload = Self.payload()
        let run = try runWrapper(payload, env: [
            "FLIGHT_DECK_USAGE_DIR": dir.path,
            "FLIGHT_DECK_SESSION_ID": Self.tab,
            ClaudeStatusLine.userCommandVariable: "cat > \(ClaudeSession.shellQuoted(seen.path)); printf '\\033[2mModel\\033[0m  82%%\\n'",
        ])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "\u{1B}[2mModel\u{1B}[0m  82%\n", "the user's text, byte for byte")
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), payload, "the user's command gets claude's stdin unchanged")

        let file = try XCTUnwrap(ClaudeUsageFile.decode(try Data(contentsOf: dir.appendingPathComponent("\(Self.tab).json"))))
        XCTAssertEqual(file.tab, Self.tab)
        XCTAssertEqual(file.session, Self.session)
        XCTAssertEqual(file.windows.map(\.name), ["five_hour", "seven_day"])
        XCTAssertEqual(file.windows[0].utilization, 0.825, accuracy: 1e-9)
        XCTAssertEqual(file.windows[1].utilization, 0.31, accuracy: 1e-9)
        XCTAssertEqual(file.windows[0].resetsAt, Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(file.readAt.timeIntervalSinceNow, 0, accuracy: 10)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path), ["\(Self.tab).json"], "no temp file left behind")
        print("statusline wrapper with a writing run: \(Int(run.seconds * 1000)) ms")
    }

    func testWithoutATabTheFileIsNamedByClaudesSessionID() throws {
        let dir = try usageDir()
        _ = try runWrapper(Self.payload(), env: ["FLIGHT_DECK_USAGE_DIR": dir.path])
        let file = try XCTUnwrap(ClaudeUsageFile.decode(try Data(contentsOf: dir.appendingPathComponent("\(Self.session).json"))))
        XCTAssertNil(file.tab)
    }

    func testNoUserCommandPrintsNothingAndNoUsageDirWritesNothing() throws {
        let dir = try usageDir()
        let quiet = try runWrapper(Self.payload(), env: ["FLIGHT_DECK_USAGE_DIR": dir.path])
        XCTAssertEqual(quiet.stdout, "", "no status line configured means none drawn")
        XCTAssertEqual(quiet.status, 0)

        let before = try fm.contentsOfDirectory(atPath: root.path).sorted()
        let run = try runWrapper(Self.payload(), env: [ClaudeStatusLine.userCommandVariable: "printf hi"])
        XCTAssertEqual(run.stdout, "hi")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).count, 1, "only the first run's file")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    /// An API-key login, or a tab before its first reply: no rate limits, no reading.
    func testNoRateLimitsWritesNoFile() throws {
        let dir = try usageDir()
        _ = try runWrapper(Self.payload(rateLimits: false), env: ["FLIGHT_DECK_USAGE_DIR": dir.path, "FLIGHT_DECK_SESSION_ID": Self.tab])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path), [])
    }

    func testAFailingUserCommandStillExitsZeroWithItsOutput() throws {
        let run = try runWrapper(Self.payload(), env: [ClaudeStatusLine.userCommandVariable: "printf partial; exit 3"])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "partial")
    }

    func testAnUnwritableUsageDirCostsTheStatusLineNothing() throws {
        let run = try runWrapper(Self.payload(), env: [
            "FLIGHT_DECK_USAGE_DIR": root.appendingPathComponent("missing").path,
            ClaudeStatusLine.userCommandVariable: "printf ok",
        ])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "ok")
    }

    /// The status line also runs on a timer and on UI events, re-sending the last API call's
    /// numbers. A rewrite would stamp them with a new readAt, and the ledger keeps the newest
    /// reading per account — an idle tab would hide a busy one's.
    func testARerunWithTheSameReadingDoesNotRewriteTheFile() throws {
        let dir = try usageDir()
        let env = ["FLIGHT_DECK_USAGE_DIR": dir.path, "FLIGHT_DECK_SESSION_ID": Self.tab]
        let url = dir.appendingPathComponent("\(Self.tab).json")
        _ = try runWrapper(Self.payload(), env: env)
        let first = try Data(contentsOf: url)
        let old = Date(timeIntervalSince1970: 1_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)

        _ = try runWrapper(Self.payload(), env: env)
        XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, old, "same reading, no write")
        XCTAssertEqual(try Data(contentsOf: url), first)

        _ = try runWrapper(Self.payload(input: 1300), env: env)
        XCTAssertNotEqual(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, old, "a new API call is a new reading")

        _ = try runWrapper(Self.payload(fiveHour: 90, input: 1300), env: env)
        let moved = try XCTUnwrap(ClaudeUsageFile.decode(try Data(contentsOf: url)))
        XCTAssertEqual(moved.windows.first?.utilization ?? 0, 0.9, accuracy: 1e-9)
    }

    // MARK: - Flag injection

    private let wrapper = URL(fileURLWithPath: "/Users/u/Library/Application Support/Flight Deck/claude-plugin-release/scripts/statusline.sh")

    private func settings(_ flags: FlagSet) throws -> [String: Any] {
        guard case .value(let raw)? = flags.values["--settings"] else { throw XCTSkip("no --settings") }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    func testInjectingAddsAQuotedWrapperStatusLine() throws {
        let out = ClaudeStatusLine.injecting(into: FlagSet(), wrapper: wrapper, user: nil, projectDirectory: nil)
        let line = try XCTUnwrap(try settings(out)["statusLine"] as? [String: Any])
        XCTAssertEqual(line["type"] as? String, "command")
        XCTAssertEqual(line["command"] as? String, "'\(wrapper.path)'", "unquoted, the space splits it and the status line exits 127")
        XCTAssertEqual(line["refreshInterval"] as? Int, 30)
        XCTAssertNil(line["padding"])
    }

    func testInjectingCarriesTheUsersLayoutSettings() throws {
        let user = ClaudeStatusLine.User(command: "x", padding: 2, hideVimModeIndicator: true, refreshInterval: 5)
        let line = try XCTUnwrap(try settings(ClaudeStatusLine.injecting(into: FlagSet(), wrapper: wrapper, user: user, projectDirectory: nil))["statusLine"] as? [String: Any])
        XCTAssertEqual(line["padding"] as? Int, 2)
        XCTAssertEqual(line["hideVimModeIndicator"] as? Bool, true)
        XCTAssertEqual(line["refreshInterval"] as? Int, 5, "a shorter interval the user chose is kept")
    }

    func testInjectingMergesIntoTheUsersInlineSettings() throws {
        var flags = FlagSet()
        flags.values["--settings"] = .value(#"{"model":"opus","statusLine":{"type":"command","command":"mine"},"env":{"A":"1"}}"#)
        let s = try settings(ClaudeStatusLine.injecting(into: flags, wrapper: wrapper, user: nil, projectDirectory: nil))
        XCTAssertEqual(s["model"] as? String, "opus")
        XCTAssertEqual(s["env"] as? [String: String], ["A": "1"])
        XCTAssertEqual((s["statusLine"] as? [String: Any])?["command"] as? String, "'\(wrapper.path)'")
    }

    func testInjectingFoldsASettingsFileInline() throws {
        let file = root.appendingPathComponent("my settings.json")
        try Data(#"{"model":"sonnet"}"#.utf8).write(to: file)
        var flags = FlagSet()
        flags.values["--settings"] = .value("my settings.json")
        let s = try settings(ClaudeStatusLine.injecting(into: flags, wrapper: wrapper, user: nil, projectDirectory: root))
        XCTAssertEqual(s["model"] as? String, "sonnet", "a relative path is the project's")
        XCTAssertNotNil(s["statusLine"])
    }

    func testInjectingLeavesAnUnreadableUserValueAlone() {
        var flags = FlagSet()
        flags.values["--settings"] = .value("/nowhere/settings.json")
        XCTAssertEqual(ClaudeStatusLine.injecting(into: flags, wrapper: wrapper, user: nil, projectDirectory: nil), flags)
        flags.values["--settings"] = .value("{not json")
        XCTAssertEqual(ClaudeStatusLine.injecting(into: flags, wrapper: wrapper, user: nil, projectDirectory: nil), flags)
    }

    func testInjectingTwiceIsTheSameAsOnce() {
        let once = ClaudeStatusLine.injecting(into: FlagSet(), wrapper: wrapper, user: nil, projectDirectory: nil)
        XCTAssertEqual(ClaudeStatusLine.injecting(into: once, wrapper: wrapper, user: nil, projectDirectory: nil), once)
    }

    /// The value is typed into the tab's shell. It must reach claude as the same JSON, and must
    /// hold no backslash: inside single quotes fish reads `\\` as an escape.
    func testTheSerialisedFlagReachesClaudeAsTheSameJSON() throws {
        let out = ClaudeStatusLine.injecting(into: FlagSet(), wrapper: wrapper, user: nil, projectDirectory: nil)
        guard case .value(let json)? = out.values["--settings"] else { return XCTFail("no --settings") }
        XCTAssertFalse(json.contains("\\"))
        let line = ClaudeFlagSerializer.serialize(out)
        XCTAssertEqual(ClaudeFlagParser.parse(line).flags.values["--settings"], .value(json))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf '%s' \(line.replacingOccurrences(of: "--settings ", with: ""))"]
        let out2 = Pipe()
        p.standardOutput = out2
        try p.run()
        let data = out2.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), json)
    }

    // MARK: - Resolving the user's status line

    private func writeSettings(_ json: String, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private func line(_ command: String, padding: Int? = nil) -> String {
        #"{"statusLine":{"type":"command","command":"\#(command)"\#(padding.map { ",\"padding\":\($0)" } ?? "")}}"#
    }

    func testTheAccountsSettingsAreTheFallbackAndATildeIsExpanded() throws {
        let home = root.appendingPathComponent("config"), project = root.appendingPathComponent("project")
        try writeSettings(line("~/.claude/statusline.sh", padding: 1), "settings.json", in: home)
        let user = try XCTUnwrap(ClaudeStatusLine.user(flags: FlagSet(), configHome: home, projectDirectory: project, home: "/Users/a b"))
        XCTAssertEqual(user.command, "'/Users/a b'/.claude/statusline.sh")
        XCTAssertEqual(user.padding, 1)
    }

    func testPrecedenceIsFlagThenLocalThenProjectThenAccount() throws {
        let home = root.appendingPathComponent("config"), project = root.appendingPathComponent("project")
        try writeSettings(line("account"), "settings.json", in: home)
        func resolved(_ flags: FlagSet = FlagSet()) -> String? {
            ClaudeStatusLine.user(flags: flags, configHome: home, projectDirectory: project)?.command
        }
        XCTAssertEqual(resolved(), "account")
        try writeSettings(line("project"), ".claude/settings.json", in: project)
        XCTAssertEqual(resolved(), "project")
        try writeSettings(line("local"), ".claude/settings.local.json", in: project)
        XCTAssertEqual(resolved(), "local")
        var flags = FlagSet()
        flags.values["--settings"] = .value(line("flag"))
        XCTAssertEqual(resolved(flags), "flag")
        try writeSettings(#"{"model":"opus"}"#, ".claude/settings.local.json", in: project)
        XCTAssertEqual(resolved(), "project", "a file without a status line does not hide a lower one")
    }

    func testOurOwnWrapperIsNeverTheUsersCommand() throws {
        let home = root.appendingPathComponent("config")
        try writeSettings(line("'\(wrapper.path)'"), "settings.json", in: home)
        XCTAssertNil(ClaudeStatusLine.user(flags: FlagSet(), configHome: home, projectDirectory: root.appendingPathComponent("p")),
                     "the wrapper running itself would recurse on every refresh")
    }

    func testNoStatusLineAnywhereIsNil() {
        XCTAssertNil(ClaudeStatusLine.user(flags: FlagSet(), configHome: root.appendingPathComponent("c"), projectDirectory: root))
    }
}
