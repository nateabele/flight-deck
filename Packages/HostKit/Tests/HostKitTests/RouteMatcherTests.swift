import XCTest
@testable import HostKit

final class RouteMatcherTests: XCTestCase {
    func testGlobOverTheJoinedArgv() {
        let matcher = RouteMatcher(routes: [Route(match: "xcodebuild test *", recipe: "ui")])
        XCTAssertEqual(matcher.match(["xcodebuild", "test", "-scheme", "FlightDeck"])?.recipe, "ui")
        XCTAssertNil(matcher.match(["xcodebuild", "build", "-scheme", "FlightDeck"]))
        // fnmatch semantics, deliberately: `test *` needs something after `test`. Predictable
        // beats clever — a user who wants bare `xcodebuild test` too writes `xcodebuild test*`.
        XCTAssertNil(matcher.match(["xcodebuild", "test"]))
    }

    /// `*` crosses argument boundaries and `/`, since the pattern is over one joined string.
    func testStarSpansSpacesAndSlashes() {
        XCTAssertTrue(RouteMatcher.glob("make * test", matches: "make -C sub/dir -j8 test"))
        XCTAssertTrue(RouteMatcher.glob("*", matches: ""))
        XCTAssertFalse(RouteMatcher.glob("make *", matches: "cmake build"))
    }

    func testQuestionMarkClassesAndEscapes() {
        XCTAssertTrue(RouteMatcher.glob("go test ./...?", matches: "go test ./...x"))
        XCTAssertTrue(RouteMatcher.glob("cargo [bt]e*", matches: "cargo test"))
        XCTAssertTrue(RouteMatcher.glob("cargo [!b]est", matches: "cargo test"))
        XCTAssertFalse(RouteMatcher.glob("cargo [!t]est", matches: "cargo test"))
        XCTAssertTrue(RouteMatcher.glob("v[0-9]", matches: "v7"))
        XCTAssertTrue(RouteMatcher.glob(#"echo \*"#, matches: "echo *"))
        XCTAssertFalse(RouteMatcher.glob(#"echo \*"#, matches: "echo x"))
        // An unclosed class is a literal `[`, as in fnmatch, never a crash.
        XCTAssertTrue(RouteMatcher.glob("a[b", matches: "a[b"))
    }

    /// Pathological backtracking must stay linear-ish: this used to be the classic exponential
    /// case for naive recursive globbers.
    func testManyStarsDoNotBlowUp() {
        let text = String(repeating: "a", count: 200)
        XCTAssertFalse(RouteMatcher.glob(String(repeating: "*a", count: 30) + "b", matches: text))
    }

    func testFirstMatchingRouteWins() {
        let matcher = RouteMatcher(routes: [
            Route(match: "swift test*", recipe: "tests"),
            Route(match: "swift *", recipe: "anything"),
        ])
        XCTAssertEqual(matcher.match(["swift", "test", "--parallel"])?.recipe, "tests")
        XCTAssertEqual(matcher.match(["swift", "build"])?.recipe, "anything")
    }

    /// The CLI may be handed `/usr/bin/xcodebuild` as argv0; the route is written against the
    /// command name.
    func testArgvZeroMatchesByBasename() {
        let matcher = RouteMatcher(routes: [Route(match: "xcodebuild test *", recipe: "ui")])
        XCTAssertEqual(matcher.match(["/usr/bin/xcodebuild", "test", "-quiet"])?.recipe, "ui")
    }

    func testEmptyArgvMatchesNothing() {
        XCTAssertNil(RouteMatcher(routes: [Route(match: "*", recipe: "a")]).match([]))
    }

    func testCommandNamesAreWhatTheShimsInstall() {
        let matcher = RouteMatcher(routes: [
            Route(match: "xcodebuild test *", recipe: "a"),
            Route(match: "xcodebuild build*", recipe: "b"),
            Route(match: "make", recipe: "c"),
            Route(match: "*build x", recipe: "d"),   // a glob: nothing to shim
            Route(match: "./run.sh *", recipe: "e"), // a path, not a PATH lookup
            Route(match: "  ", recipe: "f"),
        ])
        XCTAssertEqual(matcher.commandNames, ["make", "xcodebuild"])
    }
}
