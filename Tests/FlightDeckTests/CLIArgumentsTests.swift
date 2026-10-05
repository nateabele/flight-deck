import FleetKit
import XCTest

final class CLIArgumentsTests: XCTestCase {
    private func parse(_ s: String...) throws -> CLIInvocation { try CLIArguments.parse(s) }

    func testGlobalsAnywhere() throws {
        XCTAssertEqual(try parse("ls", "--json"), CLIInvocation(command: .ls(project: nil), json: true, socket: nil))
        XCTAssertEqual(try parse("--socket", "/s", "ls").socket, "/s")
    }
    func testNoArgumentsIsHelp() throws { XCTAssertEqual(try CLIArguments.parse([]).command, .help) }
    func testTail() throws {
        XCTAssertEqual(try parse("tail", "--session", "self", "--since", "12", "--no-snapshot").command,
                       .tail(session: "self", since: 12, noSnapshot: true))
    }
    func testWaitNeedsFor() {
        XCTAssertThrowsError(try parse("wait", "abcd"))
        XCTAssertEqual(try? parse("wait", "abcd", "--for", "idle", "--timeout", "30").command,
                       .wait(session: "abcd", condition: "idle", timeout: 30))
    }
    func testSendJoinsNothingAndTakesOneText() throws {
        XCTAssertEqual(try parse("send", "self", "hello there").command, .send(session: "self", text: "hello there"))
        XCTAssertThrowsError(try parse("send", "self"))
    }
    func testAnswerForms() throws {
        XCTAssertEqual(try parse("answer", "s", "allow").command, .answer(session: "s", choice: .allow, call: nil))
        XCTAssertEqual(try parse("answer", "s", "[[0,1],[2]]", "--call", "c").command,
                       .answer(session: "s", choice: .selections([[0, 1], [2]]), call: "c"))
        XCTAssertThrowsError(try parse("answer", "s", "[[x]]"))
    }
    func testPlan() throws {
        XCTAssertEqual(try parse("plan", "reject", "s", "--feedback", "no").command,
                       .planResolve(session: "s", approve: false, feedback: "no"))
        XCTAssertEqual(try parse("plan", "annotate", "s", "note", "--block", "3").command,
                       .planAnnotate(session: "s", text: "note", block: 3))
    }
    func testTimelineAnchors() throws {
        XCTAssertEqual(try parse("timeline", "s").command, .timeline(session: "s", anchor: .latest, limit: 40))
        XCTAssertEqual(try parse("timeline", "s", "--before", "900", "--limit", "5").command,
                       .timeline(session: "s", anchor: .before(900), limit: 5))
    }
    func testReopenNeedsAFullUUID() { XCTAssertThrowsError(try parse("reopen", "abcd")) }
    func testUnknownVerbIsAUsageError() {
        XCTAssertThrowsError(try parse("frobnicate")) { XCTAssertTrue(($0 as? CLIUsageError)?.message.contains("frobnicate") == true) }
    }
    // MARK: Final-review fixes

    func testHostLs() throws { XCTAssertEqual(try parse("host", "ls").command, .hostList) }
    func testHostInfo() throws { XCTAssertEqual(try parse("host", "info", "mini").command, .hostInfo(name: "mini")) }
    func testHostInfoRequiresName() {
        XCTAssertEqual(usageMessage("host", "info"), "host info: missing host")
        XCTAssertEqual(usageMessage("host"), "host: missing subcommand")
        XCTAssertEqual(usageMessage("host", "rm", "mini"), #"host: unknown subcommand "rm""#)
        XCTAssertEqual(usageMessage("host", "ls", "mini"), #"unexpected argument "mini""#)
    }

    private func usageMessage(_ args: String...) -> String? {
        do { _ = try CLIArguments.parse(args); return nil }
        catch { return (error as? CLIUsageError)?.message }
    }

    /// The documented syntax. Read as two positionals, this sent `projectPath = "--project"`.
    func testOpenTakesTheDocumentedProjectFlag() throws {
        XCTAssertEqual(try parse("open", "conv-1", "--project", "/w/a").command,
                       .open(conversation: "conv-1", projectPath: "/w/a"))
        XCTAssertNotNil(usageMessage("open", "conv-1"), "--project is required")
    }

    /// Every verb refuses what it did not consume, rather than silently dropping it.
    func testATrailingOperandIsAUsageErrorNamingIt() {
        XCTAssertEqual(usageMessage("close", "a", "b"), #"unexpected argument "b""#)
        XCTAssertEqual(usageMessage("ls", "a", "b"), #"unexpected argument "b""#)
        XCTAssertEqual(usageMessage("wait", "s", "--for", "idle", "extra"), #"unexpected argument "extra""#)
        XCTAssertEqual(usageMessage("plan", "approve", "s", "t"), #"unexpected argument "t""#)
        XCTAssertEqual(usageMessage("send", "s", "one", "two"), #"unexpected argument "two""#)
    }

    /// FleetService reads a nil on either side as a plain `+`, so a lone `--account` would
    /// silently open the default agent.
    func testAccountWithoutAgentIsAUsageError() throws {
        XCTAssertNotNil(usageMessage("new", "p", "--account", "1"))
        XCTAssertEqual(try parse("new", "p", "--agent", "codex").command,
                       .new(project: "p", agent: "codex", account: 0))
        XCTAssertEqual(try parse("new", "p", "--agent", "codex", "--account", "2").command,
                       .new(project: "p", agent: "codex", account: 2))
    }

    func testWaitForTakesOnlyARealCondition() {
        XCTAssertNotNil(usageMessage("wait", "s", "--for", "idel"))
        for condition in ["idle", "busy", "waiting", "gone"] {
            XCTAssertNil(usageMessage("wait", "s", "--for", condition), condition)
        }
    }

    /// `--json` is a global stripped from any position, so without `--` it can never be text.
    func testDoubleDashEndsOptions() throws {
        let parsed = try parse("send", "s", "--", "--json")
        XCTAssertEqual(parsed.command, .send(session: "s", text: "--json"))
        XCTAssertFalse(parsed.json)
        XCTAssertEqual(try parse("rename", "s", "--", "--socket").command, .rename("s", title: "--socket"))
    }

    func testSendWaitAndItsTimeout() {
        XCTAssertNil(usageMessage("send", "s", "hi", "--wait", "--timeout", "60"))
        XCTAssertNotNil(usageMessage("send", "s", "hi", "--timeout", "60"), "--timeout needs --wait")
        // Flag-shaped text is refused rather than typed into the agent; `--` is the way to send it.
        XCTAssertNotNil(usageMessage("send", "s", "--wait"))
        XCTAssertEqual(try? parse("send", "s", "--", "--wait").command, .send(session: "s", text: "--wait"))
        XCTAssertEqual(try? parse("send", "s", "hi", "--wait", "--timeout", "60").command,
                       .send(session: "s", text: "hi", wait: true, timeout: 60))
    }
    // MARK: Flags anywhere before `--`

    /// A verb's flags may come before or after its operands, and `--` ends flag parsing — so
    /// text starting with `-` combines with any flag instead of excluding them all.
    func testSendFlagsMayComeBeforeOrAfterTheTextAndDoubleDashEndsThem() throws {
        XCTAssertEqual(try parse("send", "S", "--wait", "--", "- fix the tests").command,
                       .send(session: "S", text: "- fix the tests", wait: true))
        XCTAssertEqual(try parse("send", "S", "text", "--wait").command,
                       .send(session: "S", text: "text", wait: true))
        XCTAssertEqual(try parse("send", "S", "--wait", "text").command,
                       .send(session: "S", text: "text", wait: true))
        XCTAssertEqual(try parse("send", "S", "--", "--json").command,
                       .send(session: "S", text: "--json"))
        XCTAssertEqual(try parse("send", "S", "--timeout", "5", "--wait", "--", "-x").command,
                       .send(session: "S", text: "-x", wait: true, timeout: 5))
    }

    func testOtherVerbsTakeFlagsWithADashLedOperandAfterDoubleDash() throws {
        XCTAssertEqual(try parse("search", "--limit", "5", "--", "-x").command, .search(query: "-x", limit: 5))
        XCTAssertEqual(try parse("plan", "annotate", "S", "--block", "3", "--", "- note").command,
                       .planAnnotate(session: "S", text: "- note", block: 3))
        XCTAssertEqual(try parse("timeline", "--before", "-1", "--", "-s").command,
                       .timeline(session: "-s", anchor: .before(-1), limit: 40))
        XCTAssertEqual(try parse("ls", "--project", "P").command, .ls(project: "P"))
        XCTAssertEqual(try parse("ls", "P").command, .ls(project: "P"))
    }

    /// An unknown flag before `--` is never read as text: it would be typed into an agent.
    func testAnUnknownFlagBeforeDoubleDashIsStillAUsageError() {
        let message = usageMessage("send", "S", "-x")
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains(#"flightdeck send S --wait -- "- text""#) == true,
                      "the hint names a form that works: \(message ?? "nil")")
        XCTAssertNotNil(usageMessage("send", "S", "hi", "--bogus"))
        // main.swift prints "flightdeck: " before every usage message, so the message must
        // name the verb, never the program a second time.
        for verb in ["close", "read", "raw"] {
            let printed = "flightdeck: " + (usageMessage(verb, "S", "--bogus") ?? "")
            XCTAssertTrue(printed.hasPrefix("flightdeck: \(verb): "), printed)
            XCTAssertTrue(printed.contains(#"unknown flag "--bogus""#), printed)
            XCTAssertFalse(printed.contains("flightdeck: flightdeck"), printed)
        }
        XCTAssertNotNil(usageMessage("search", "--limit", "--", "5"), "a flag's value never comes from past --")
    }
}
