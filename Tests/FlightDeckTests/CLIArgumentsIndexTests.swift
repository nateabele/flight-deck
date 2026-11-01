import XCTest

/// `index ARGS…`: everything after `index` goes to `fdindex`, found beside `flightdeck` or on PATH.
final class CLIArgumentsIndexTests: XCTestCase {
    private func parse(_ s: String...) throws -> CLIInvocation { try CLIArguments.parse(s) }

    func testEverythingAfterIndexIsPassedThroughUntouched() throws {
        XCTAssertEqual(try parse("index", "find", "traverseStep").command, .index(["find", "traverseStep"]))
        XCTAssertEqual(try parse("index", "status").command, .index(["status"]))
        XCTAssertEqual(try parse("index", "install").command, .index(["install"]))
    }

    func testFlightdecksGlobalsAreFdindexsFlagsAfterIndex() throws {
        // `--json`, `--socket` and `--help` would be flightdeck's anywhere else.
        let invocation = try parse("index", "find", "x", "--json", "--socket", "/tmp/s", "--cwd", "/w")
        XCTAssertEqual(invocation.command, .index(["find", "x", "--json", "--socket", "/tmp/s", "--cwd", "/w"]))
        XCTAssertFalse(invocation.json)
        XCTAssertNil(invocation.socket)
        XCTAssertEqual(try parse("index", "find", "--help").command, .index(["find", "--help"]))
        XCTAssertEqual(try parse("index", "grep", "--", "-x").command, .index(["grep", "--", "-x"]))
    }

    func testBareIndexAndIndexHelpShowTheIndexPage() throws {
        XCTAssertEqual(try parse("index").command, .help(topic: "index"))
        XCTAssertEqual(try parse("index", "--help").command, .help(topic: "index"))
        XCTAssertEqual(try parse("help", "index").command, .help(topic: "index"))
    }

    func testIndexIsInTheHelpOverviewWithItsCommands() {
        XCTAssertNotNil(CLIHelp.topic(for: ["index", "find"]))
        XCTAssertTrue(CLIHelp.overview.contains("index"))
        let page = CLIHelp.text(for: "index")
        for word in ["find NAME", "status", "install | uninstall", "FLIGHTDECK_FDINDEX", "127"] where !page.contains(word) {
            XCTFail("the index page does not mention \(word)")
        }
    }
}

final class IndexCommandTests: XCTestCase {
    private let flightdeck = URL(fileURLWithPath: "/App/Flight Deck.app/Contents/MacOS/flightdeck")

    private func locate(_ env: [String: String] = [:], executable: URL? = nil, existing: Set<String>) -> String? {
        if case .success(let path) = IndexCommand.locate(environment: env, executable: executable, isExecutable: existing.contains) {
            return path
        }
        return nil
    }

    func testTheOverrideWinsOverEverything() {
        let env = ["FLIGHTDECK_FDINDEX": "/custom/fdindex", "PATH": "/usr/bin"]
        let existing: Set<String> = ["/custom/fdindex", "/App/Flight Deck.app/Contents/MacOS/fdindex", "/usr/bin/fdindex"]
        XCTAssertEqual(locate(env, executable: flightdeck, existing: existing), "/custom/fdindex")
    }

    func testAnOverrideThatPointsNowhereIsAnErrorNotAFallback() {
        let result = IndexCommand.locate(
            environment: ["FLIGHTDECK_FDINDEX": "/nope", "PATH": "/usr/bin"], executable: flightdeck,
            isExecutable: { $0 == "/usr/bin/fdindex" })
        guard case .failure(let error) = result else { return XCTFail("fell back to PATH") }
        XCTAssertTrue(error.message.contains("/nope"))
    }

    func testBesideTheRunningCLIBeatsPATH() {
        let existing: Set<String> = ["/App/Flight Deck.app/Contents/MacOS/fdindex", "/usr/bin/fdindex"]
        XCTAssertEqual(locate(["PATH": "/usr/bin"], executable: flightdeck, existing: existing),
                       "/App/Flight Deck.app/Contents/MacOS/fdindex")
    }

    func testPATHIsSearchedInOrder() {
        XCTAssertEqual(locate(["PATH": "/a:/b:/c"], existing: ["/b/fdindex", "/c/fdindex"]), "/b/fdindex")
    }

    func testMissingExplainsWhereItLooked() {
        guard case .failure(let error) = IndexCommand.locate(environment: ["PATH": "/a"], executable: flightdeck, isExecutable: { _ in false }) else {
            return XCTFail("found something")
        }
        XCTAssertTrue(error.message.contains("cannot find fdindex"))
        XCTAssertTrue(error.message.contains("FLIGHTDECK_FDINDEX"))
    }

    func testRunHandsArgvToFdindexAndNeverTouchesTheApp() {
        var launched: (String, [String])?
        var messages: [String] = []
        let status = IndexCommand.run(
            ["find", "traverseStep", "--json"], environment: ["FLIGHTDECK_FDINDEX": "/bin/sh"], executable: nil,
            report: { messages.append($0) },
            exec: { launched = ($0, $1); return ENOEXEC })
        XCTAssertEqual(launched?.0, "/bin/sh")
        XCTAssertEqual(launched?.1, ["fdindex", "find", "traverseStep", "--json"])
        // A real exec never returns; one that did is a failure to run, and says why.
        XCTAssertEqual(status, IndexCommand.notFoundStatus)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("cannot run /bin/sh"))
    }

    func testRunReportsAndReturns127WhenThereIsNoFdindex() {
        var messages: [String] = []
        let status = IndexCommand.run(["status"], environment: ["PATH": "/nonexistent"], executable: nil, report: { messages.append($0) },
                                      exec: { _, _ in XCTFail("exec without a binary"); return 0 })
        XCTAssertEqual(status, 127)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].hasPrefix("flightdeck: index: cannot find fdindex"))
    }
}
