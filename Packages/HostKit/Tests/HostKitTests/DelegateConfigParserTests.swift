import XCTest
@testable import HostKit

final class DelegateConfigParserTests: XCTestCase {
    /// Spec §8's example, verbatim. Every field it shows must land in the typed config.
    static let specExample = #"""
    default_host = "mini"
    include = [".env"]                  # declared ignored files, every run

    [recipe.ui-tests]
    host = "mini"
    run = "xcodebuild test -scheme FlightDeck -only-testing:UITests"
    screen = true
    long = true
    fetch = ["build/**/*.xcresult"]
    apply = "review"                    # or "auto"

    [recipe.stack]
    host = "linuxbox"
    run = "docker compose up"
    down = "docker compose down"
    ports = [5432, "8080:80"]
    service = true

    [[route]]                           # transparent routing
    match = "xcodebuild test *"         # glob over the joined argv
    recipe = "ui-tests"
    """#

    func testParsesTheFullSpecExample() throws {
        let result = try DelegateConfigParser.parse(Self.specExample)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.config, DelegateConfig(
            defaultHost: "mini",
            include: [".env"],
            recipes: [
                "ui-tests": Recipe(
                    host: "mini", run: "xcodebuild test -scheme FlightDeck -only-testing:UITests",
                    screen: true, long: true, fetch: ["build/**/*.xcresult"], apply: .review),
                "stack": Recipe(
                    host: "linuxbox", run: "docker compose up", down: "docker compose down",
                    service: true, ports: ["5432", "8080:80"]),
            ],
            routes: [Route(match: "xcodebuild test *", recipe: "ui-tests")]))
        XCTAssertEqual(result.config.validate(hosts: ["mini": "macOS", "linuxbox": "Linux"]), [])
    }

    func testEmptyFileIsAnEmptyConfig() throws {
        XCTAssertEqual(try DelegateConfigParser.parse("").config, DelegateConfig())
        XCTAssertEqual(try DelegateConfigParser.parse("# nothing yet\n\n").config, DelegateConfig())
    }

    func testEveryRecipeFieldAndTheSyntaxAroundIt() throws {
        let text = #"""
        [recipe."my tests"]   # a quoted name
        run = 'make  "test"'
        restart_on_sync = true
        pool = 3
        apply = "auto"
        env = { RUST_LOG = "debug", "WITH SPACE" = "a\tbé" }
        ports = [
          5432,        # postgres
          "auto:3000",
        ]

        [recipe.svc.env]
        TOKEN = "x"

        [recipe.svc]
        run = "serve"
        """#
        let config = try DelegateConfigParser.parse(text).config
        XCTAssertEqual(config.recipes["my tests"], Recipe(
            run: #"make  "test""#, restartOnSync: true, ports: ["5432", "auto:3000"],
            env: ["RUST_LOG": "debug", "WITH SPACE": "a\tbé"], apply: .auto, pool: 3))
        // A subtable may precede its parent's header; TOML allows it, so a hand-edited file
        // that does so must not fail.
        XCTAssertEqual(config.recipes["svc"], Recipe(run: "serve", env: ["TOKEN": "x"]))
    }

    func testRoutesKeepFileOrder() throws {
        let text = """
        [recipe.a]
        run = "a"
        [[route]]
        match = "swift test*"
        recipe = "a"
        [[route]]
        match = "swift *"
        recipe = "a"
        """
        XCTAssertEqual(try DelegateConfigParser.parse(text).config.routes.map(\.match),
                       ["swift test*", "swift *"])
    }

    // MARK: - Unknown keys warn, they do not fail

    func testUnknownKeysAreWarningsNotErrors() throws {
        let text = """
        default_host = "mini"
        colour = "blue"

        [recipe.a]
        run = "a"
        timeout = 30

        [[route]]
        match = "a *"
        recipe = "a"
        weight = 2

        [future]
        x = 1
        """
        let result = try DelegateConfigParser.parse(text)
        XCTAssertEqual(result.config.defaultHost, "mini")
        XCTAssertEqual(result.config.recipes["a"], Recipe(run: "a"))
        XCTAssertEqual(result.warnings.map(\.severity), [.warning, .warning, .warning, .warning])
        XCTAssertEqual(result.warnings.map(\.line), [2, 6, 11, 13])
        XCTAssertTrue(result.warnings[0].message.contains("colour"), result.warnings[0].message)
        XCTAssertTrue(result.warnings[1].message.contains("recipe.a.timeout"), result.warnings[1].message)
    }

    // MARK: - One case per parse error, each naming its line

    func testParseErrors() {
        let cases: [(String, Int, String)] = [
            ("default_host = mini", 1, "value"),                        // bare word
            ("default_host = \"mini", 1, "unterminated"),
            ("include = [\".env\"", 1, "array"),
            ("default_host = \"a\"\ndefault_host = \"b\"", 2, "duplicate"),
            ("[recipe.a]\nrun = \"a\"\n[recipe.a]\nrun = \"b\"", 3, "defined twice"),
            ("[recipe.a\nrun = \"a\"", 1, "]"),
            ("[recipe.a]\nscreen = true", 1, "run"),                    // run is required
            ("[recipe.a]\nrun = \"a\"\nscreen = \"yes\"", 3, "true or false"),
            ("[recipe.a]\nrun = \"a\"\napply = \"sometimes\"", 3, "review"),
            ("[recipe.a]\nrun = \"a\"\nports = [true]", 3, "ports"),
            ("[recipe.a]\nrun = \"a\"\npool = \"two\"", 3, "integer"),
            ("[recipe.a]\nrun = \"a\"\nenv = { A = 1 }", 3, "string"),
            ("include = \".env\"", 1, "array"),
            ("recipe = 3", 1, "table"),
            ("[[route]]\nrecipe = \"a\"", 1, "match"),
            ("[[route]]\nmatch = \"a *\"", 1, "recipe"),
            ("run = \"\"\"multi\"\"\"", 1, "multi-line"),
            ("pool = 1.5e3", 1, "value"),
            ("key = \"a\" trailing", 1, "end of line"),
            ("= \"a\"", 1, "key"),
            ("x = \"bad \\q escape\"", 1, "escape"),
        ]
        for (text, line, fragment) in cases {
            XCTAssertThrowsError(try DelegateConfigParser.parse(text), text) { error in
                guard let issue = error as? DelegateConfigIssue else {
                    return XCTFail("\(text): not a DelegateConfigIssue: \(error)")
                }
                XCTAssertEqual(issue.severity, .error, text)
                XCTAssertEqual(issue.line, line, "\(text) → \(issue)")
                XCTAssertTrue(issue.message.localizedCaseInsensitiveContains(fragment),
                              "\(text) → \(issue.message) lacks \(fragment)")
            }
        }
    }

    /// The file is checked in, so a cloned repo controls it. Recursion without a bound let a
    /// `[[[…` 100,000 deep overflow the stack and take Flight Deck down at every launch.
    func testDeepNestingIsAnErrorNotACrash() {
        let depth = 100_000
        for text in ["x = " + String(repeating: "[", count: depth),
                     "x = " + String(repeating: "{a=", count: depth)] {
            XCTAssertThrowsError(try DelegateConfigParser.parse(text)) { error in
                XCTAssertEqual((error as? DelegateConfigIssue)?.message, "arrays nested too deeply")
            }
        }
        // 32 levels is the limit, and still parses.
        let ok = "x = " + String(repeating: "[", count: 32) + String(repeating: "]", count: 32)
        XCTAssertNoThrow(try DelegateConfigParser.parse(ok))
    }

    /// A dotted path 100,000 long built a 100,000-deep chain of tables, and freeing it
    /// recursed in deinit until the stack overflowed — the same crash as deep arrays, through
    /// keys instead of values.
    func testDeepKeyPathsAreAnErrorNotACrash() {
        let path = Array(repeating: "a", count: 100_000).joined(separator: ".")
        for text in ["[\(path)]", "[[\(path)]]", "\(path) = 1"] {
            XCTAssertThrowsError(try DelegateConfigParser.parse(text)) { error in
                XCTAssertEqual((error as? DelegateConfigIssue)?.message, "keys nested too deeply")
            }
        }
        // An inline table takes a single key, so a dotted one is refused before any table is
        // built; the point is that it is an error and not a crash.
        XCTAssertThrowsError(try DelegateConfigParser.parse("x = { \(path) = 1 }"))
        let ok = Array(repeating: "a", count: 32).joined(separator: ".")
        XCTAssertNoThrow(try DelegateConfigParser.parse("[\(ok)]\n\(ok) = 1"))
    }

    /// Editors on Windows (and some on macOS) save a UTF-8 BOM; it is not a key.
    func testLeadingByteOrderMarkIsSkipped() throws {
        XCTAssertEqual(try DelegateConfigParser.parse("\u{FEFF}default_host = \"mini\"").config.defaultHost, "mini")
    }

    /// TOML forbids raw control characters in strings; one in a `run` command would reach a
    /// shell on another machine as something no reviewer of the file could see.
    func testRawControlCharactersInStringsAreErrors() {
        for text in ["run = \"a\u{01}b\"", "run = 'a\u{1B}[2Jb'", "run = \"a\u{7F}\""] {
            XCTAssertThrowsError(try DelegateConfigParser.parse(text), text) { error in
                XCTAssertTrue((error as? DelegateConfigIssue)?.message.contains("control character") == true, "\(error)")
            }
        }
        // A tab is allowed raw, and an escaped newline is just a newline.
        XCTAssertNoThrow(try DelegateConfigParser.parse("[recipe.a]\nrun = \"a\tb\\nc\""))
    }

    func testNonUTF8FileIsAnIssueNotACocoaError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = DelegateConfigParser.fileURL(projectRoot: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x72, 0x75, 0x6E, 0x20, 0x3D, 0x20, 0xFF, 0xFE]).write(to: file)
        XCTAssertThrowsError(try DelegateConfigParser.load(projectRoot: root)) { error in
            let issue = error as? DelegateConfigIssue
            XCTAssertEqual(issue?.severity, .error)
            XCTAssertTrue(issue?.message.contains("UTF-8") == true, "\(error)")
        }
    }

    func testIssueDescriptionNamesTheFileLineAndSeverity() {
        let issue = DelegateConfigIssue(.error, line: 4, "recipe.a.screen must be true or false")
        XCTAssertEqual(issue.description, "delegate.toml:4: error: recipe.a.screen must be true or false")
        XCTAssertEqual(DelegateConfigIssue(.warning, "unknown host \"x\"").description,
                       "delegate.toml: warning: unknown host \"x\"")
    }

    // MARK: - validate()

    func testUnknownHostIsAWarning() {
        let config = DelegateConfig(defaultHost: "ghost", recipes: ["a": Recipe(host: "phantom", run: "a")])
        let issues = config.validate(hosts: ["mini": "macOS"])
        XCTAssertEqual(issues.map(\.severity), [.warning, .warning])
        XCTAssertTrue(issues.contains { $0.message.contains("ghost") })
        XCTAssertTrue(issues.contains { $0.message.contains("phantom") })
        // Without host knowledge (a `recipe check` with nothing paired yet) there is nothing to
        // compare against, so it says nothing rather than calling every host unknown.
        XCTAssertEqual(config.validate(), [])
    }

    func testServiceWithoutPortsIsFine() {
        let config = DelegateConfig(recipes: ["s": Recipe(run: "serve", service: true)])
        XCTAssertEqual(config.validate(), [])
    }

    func testPortsMustParse() {
        let config = DelegateConfig(recipes: ["s": Recipe(run: "serve", ports: ["5432", "80:", "70000"])])
        let issues = config.validate()
        XCTAssertEqual(issues.map(\.severity), [.error, .error])
        XCTAssertTrue(issues[0].message.contains("\"80:\""), issues[0].message)
        XCTAssertTrue(issues[1].message.contains("\"70000\""), issues[1].message)
    }

    /// `--port L:R` replaces "the recipe's entry for the same remote port" (§6.2): two entries
    /// for one R would make that replacement ambiguous.
    func testTwoMappingsForOneRemotePortIsAnError() {
        let config = DelegateConfig(recipes: ["s": Recipe(run: "serve", ports: ["5432", "15432:5432"])])
        XCTAssertEqual(config.validate().map(\.severity), [.error])
    }

    /// Parse time knows nothing about hosts, so a Linux screen recipe parses fine; the error
    /// appears only once preflight (or `recipe check`) supplies the host's platform.
    func testScreenOnALinuxHostIsAnErrorOnlyAtPreflight() throws {
        let text = """
        default_host = "linuxbox"
        [recipe.ui]
        run = "xvfb-run test"
        screen = true
        """
        let config = try DelegateConfigParser.parse(text).config
        XCTAssertEqual(config.validate(), [])
        let issues = config.validate(hosts: ["linuxbox": "Linux"])
        XCTAssertEqual(issues.map(\.severity), [.error])
        XCTAssertTrue(issues[0].message.contains("screen"), issues[0].message)
        XCTAssertEqual(config.validate(hosts: ["linuxbox": "macOS"]), [])
    }

    func testRouteToAMissingRecipeIsAnError() {
        let config = DelegateConfig(routes: [Route(match: "make *", recipe: "nope")])
        let issues = config.validate()
        XCTAssertEqual(issues.map(\.severity), [.error])
        XCTAssertTrue(issues[0].message.contains("nope"), issues[0].message)
    }

    /// A route can only be shimmed by its command name; a glob there has no file to shim.
    func testRouteWhoseCommandIsAGlobWarns() {
        let config = DelegateConfig(recipes: ["a": Recipe(run: "a")],
                                    routes: [Route(match: "*build test", recipe: "a")])
        XCTAssertEqual(config.validate().map(\.severity), [.warning])
    }

    func testEmptyRunAndBadPoolAreErrors() {
        let config = DelegateConfig(recipes: ["a": Recipe(run: "  "), "b": Recipe(run: "b", pool: 0)])
        XCTAssertEqual(config.validate().map(\.severity), [.error, .error])
    }

    // MARK: - load

    func testLoadReadsTheProjectFileAndIsNilWhenAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(try DelegateConfigParser.load(projectRoot: root))
        let file = DelegateConfigParser.fileURL(projectRoot: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.specExample.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try DelegateConfigParser.load(projectRoot: root)?.config.defaultHost, "mini")
    }

    func testFloatLexes() throws {
        var reader = TOMLReader("a = 1.25\nb = -0.5\nc = 3\n")
        let table = try reader.read().root
        guard case .value(.float(let a), _) = table.entries["a"]!,
              case .value(.float(let b), _) = table.entries["b"]!,
              case .value(.int(3), _) = table.entries["c"]! else { return XCTFail("\(table.entries)") }
        XCTAssertEqual(a, 1.25)
        XCTAssertEqual(b, -0.5)
    }

    func testFloatValueReachesInfraMaxHourly() throws {
        let config = try DelegateConfigParser.parse("""
        [recipe.x]
        run = "make"

        [infra.g]
        preset = "aws-linux"
        region = "us-east-1"
        instance_type = "g6.xlarge"
        ttl = "1h"
        max_hourly = 1.50
        """).config
        XCTAssertEqual(config.infra["g"]?.maxHourly, 1.5)
    }
}
