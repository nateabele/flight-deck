import FleetKit
import XCTest

/// `CLIArguments` for the delegation verbs (spec §5): one test per verb and flag. Kept apart
/// from `CLIArgumentsTests` so the parallel delegation tracks never edit the same file.
final class DelegationCLIArgumentsTests: XCTestCase {
    private func parse(_ s: String...) throws -> CLICommand { try CLIArguments.parse(s).command }
    private func usage(_ s: String...) -> String? {
        do { _ = try CLIArguments.parse(s); return nil } catch let e as CLIUsageError { return e.message } catch { return "\(error)" }
    }

    func testRunWithACommandAfterDoubleDash() throws {
        XCTAssertEqual(try parse("run", "--", "xcodebuild", "test", "-scheme", "My App"),
                       .delegate(.run(WireDelegateRun(cwd: "", command: ["xcodebuild", "test", "-scheme", "My App"]))))
    }

    func testRunEveryFlag() throws {
        let parsed = try parse("run", "--on", "mini", "--include", ".env", "--include", "secrets.json",
                               "--fetch", "build/**/*.xcresult", "--env", "A=1", "--env", "B=x=y",
                               "--pty", "--screen", "--detach", "--", "make", "--json")
        XCTAssertEqual(parsed, .delegate(.run(WireDelegateRun(
            cwd: "", host: "mini", command: ["make", "--json"], include: [".env", "secrets.json"],
            fetch: ["build/**/*.xcresult"], env: ["A": "1", "B": "x=y"], pty: true, screen: true, detach: true))))
    }

    func testRunARecipeWithExtraArgs() throws {
        XCTAssertEqual(try parse("run", "ui-tests", "--on", "mini", "--", "-only-testing:X"),
                       .delegate(.run(WireDelegateRun(cwd: "", host: "mini", recipe: "ui-tests", command: ["-only-testing:X"]))))
        XCTAssertEqual(try parse("run", "ui-tests"), .delegate(.run(WireDelegateRun(cwd: "", recipe: "ui-tests"))))
    }

    func testRunRefusesNothingToRunAndBadEnvAndTwoRecipes() {
        XCTAssertNotNil(usage("run"))
        XCTAssertNotNil(usage("run", "--on", "mini"))
        XCTAssertEqual(usage("run", "--env", "NOEQUALS", "--", "x"), #"run: --env expects KEY=VALUE, got "NOEQUALS""#)
        XCTAssertNotNil(usage("run", "a", "b", "--", "x"), "only one operand, the recipe, goes before --")
        XCTAssertNotNil(usage("run", "--bogus", "--", "x"))
    }

    func testExecTakesNoRecipe() throws {
        XCTAssertEqual(try parse("exec", "--on", "mini", "--", "git", "status"),
                       .delegate(.exec(WireDelegateRun(cwd: "", host: "mini", command: ["git", "status"]))))
        XCTAssertNotNil(usage("exec", "stack", "--", "ls"))
    }

    func testUpWithPortsAndNoDetach() throws {
        XCTAssertEqual(try parse("up", "stack", "--port", "15432:5432", "--port", "auto:3000"),
                       .delegate(.up(WireDelegateRun(cwd: "", recipe: "stack", ports: ["15432:5432", "auto:3000"]))))
        XCTAssertEqual(try parse("up", "--on", "box", "--port", "8080", "--", "python", "-m", "http.server"),
                       .delegate(.up(WireDelegateRun(cwd: "", host: "box", command: ["python", "-m", "http.server"], ports: ["8080"]))))
        XCTAssertNotNil(usage("up", "stack", "--detach"), "a service is always detached")
    }

    func testServiceVerbs() throws {
        XCTAssertEqual(try parse("down", "stack"), .delegate(.down("stack")))
        XCTAssertEqual(try parse("restart", "r4"), .delegate(.restart("r4")))
        XCTAssertEqual(try parse("sync", "stack"), .delegate(.sync("stack")))
        XCTAssertNotNil(usage("down"))
    }

    func testPsLogsStopDiffApply() throws {
        XCTAssertEqual(try parse("ps"), .delegate(.ps))
        XCTAssertEqual(try parse("logs", "r3"), .delegate(.logs(run: "r3", follow: false, from: nil)))
        XCTAssertEqual(try parse("logs", "r3", "--follow", "--from", "4096"), .delegate(.logs(run: "r3", follow: true, from: 4096)))
        XCTAssertEqual(try parse("logs", "-f", "r3"), .delegate(.logs(run: "r3", follow: true, from: nil)))
        XCTAssertEqual(try parse("stop", "r3"), .delegate(.stop("r3")))
        XCTAssertEqual(try parse("diff", "r3"), .delegate(.diff("r3")))
        XCTAssertEqual(try parse("apply", "r3"), .delegate(.apply("r3")))
        XCTAssertNotNil(usage("ps", "extra"))
    }

    /// `wait r7` is a run; `wait S --for idle` is still a session, and `wait abcd` without
    /// `--for` is still refused (CLIArgumentsTests.testWaitNeedsFor pins that side).
    func testWaitOnARunIsToldApartByItsId() throws {
        XCTAssertEqual(try parse("wait", "r7"), .delegate(.wait(run: "r7", timeout: nil, from: nil)))
        XCTAssertEqual(try parse("wait", "r7", "--from", "10"), .delegate(.wait(run: "r7", timeout: nil, from: 10)))
        XCTAssertNotNil(usage("wait", "s", "--for", "idle", "--from", "1"), "--from is a run's, never a session's")
        XCTAssertEqual(try parse("wait", "r7", "--timeout", "60"), .delegate(.wait(run: "r7", timeout: 60, from: nil)))
        XCTAssertEqual(try parse("wait", "r7", "--for", "idle"), .wait(session: "r7", condition: "idle", timeout: nil))
        XCTAssertEqual(usage("wait", "rx"), "wait: --for is required")
    }

    func testRecipeVerbs() throws {
        XCTAssertEqual(try parse("recipe", "ls"), .delegate(.recipeList))
        XCTAssertEqual(try parse("recipe", "check"), .delegate(.recipeCheck))
        XCTAssertEqual(
            try parse("recipe", "add", "stack", "--run", "docker compose up", "--host", "box", "--down",
                      "docker compose down", "--service", "--restart-on-sync", "--port", "5432", "--env", "K=V",
                      "--apply", "auto", "--pool", "3", "--fetch", "out/*", "--screen", "--long"),
            .delegate(.recipeAdd(WireRecipe(name: "stack", host: "box", run: "docker compose up",
                                            down: "docker compose down", screen: true, long: true, service: true,
                                            restartOnSync: true, fetch: ["out/*"], ports: ["5432"], env: ["K": "V"],
                                            apply: "auto", pool: 3))))
        XCTAssertEqual(usage("recipe", "add", "x"), "recipe add: --run CMD is required")
        XCTAssertNotNil(usage("recipe", "add", "x", "--run", "y", "--apply", "sometimes"))
        XCTAssertNotNil(usage("recipe", "frob"))
    }

    func testHostDiskAndPrune() throws {
        XCTAssertEqual(try parse("host", "ls"), .hostList)
        XCTAssertEqual(try parse("host", "ls", "--disk"), .delegate(.hostDisk(host: nil)))
        XCTAssertEqual(try parse("host", "ls", "--disk", "mini"), .delegate(.hostDisk(host: "mini")))
        XCTAssertEqual(try parse("host", "prune", "mini"), .delegate(.hostPrune(host: "mini", repo: nil)))
        XCTAssertEqual(try parse("host", "prune", "mini", "--repo", "abc"), .delegate(.hostPrune(host: "mini", repo: "abc")))
        XCTAssertNotNil(usage("host", "prune"))
    }

    func testRouteExecKeepsTheArgvVerbatim() throws {
        XCTAssertEqual(try parse("route-exec", "xcodebuild", "--", "test", "--json", "-scheme", "X"),
                       .delegate(.routeExec(argv0: "xcodebuild", args: ["test", "--json", "-scheme", "X"])))
        XCTAssertEqual(try parse("route-exec", "make", "--"), .delegate(.routeExec(argv0: "make", args: [])))
    }

    func testRequestFillsCwdAndSizesOnlyAPty() {
        let pty = DelegateCommand.run(WireDelegateRun(cwd: "", command: ["top"], pty: true))
        XCTAssertEqual(pty.request(cwd: "/w/a", columns: 80, rows: 24),
                       .run(WireDelegateRun(cwd: "/w/a", command: ["top"], pty: true, columns: 80, rows: 24)))
        let piped = DelegateCommand.run(WireDelegateRun(cwd: "", command: ["ls"]))
        XCTAssertEqual(piped.request(cwd: "/w/a", columns: 80, rows: 24), .run(WireDelegateRun(cwd: "/w/a", command: ["ls"])))
        XCTAssertEqual(DelegateCommand.down("stack").request(cwd: "/w/a", columns: nil, rows: nil),
                       .down(service: "stack", cwd: "/w/a"))
    }
}
