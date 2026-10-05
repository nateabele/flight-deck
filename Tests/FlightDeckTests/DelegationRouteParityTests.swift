import FleetKit
import HostKit
import XCTest

/// The CLI's `route-exec` and the app route with the same rule: the CLI's copy of the glob
/// must give HostKit's `RouteMatcher` answer for every pattern and line here, or a command the
/// app would route could run locally (or the reverse).
final class DelegationRouteParityTests: XCTestCase {
    func testTheCLIRoutesExactlyAsRouteMatcherDoes() {
        let patterns = ["xcodebuild test *", "make", "make *", "*build*", "npm run [a-c]*", "npm run [!x]*", "npm run [^x]*",
                        "go test ./...", "cargo t?st *", #"echo \*"#, "pytest [", "a*a*a*b", "*", "x[]]y", "swift build -c release"]
        let lines = [["xcodebuild", "test", "-scheme", "X"], ["/usr/bin/xcodebuild", "test", "a/b"], ["xcodebuild", "test"],
                     ["make"], ["make", "all"], ["npm", "run", "build"], ["npm", "run", "xyz"], ["go", "test", "./..."],
                     ["cargo", "test", "x"], ["echo", "*"], ["echo", "x"], ["pytest", "["], ["a", "aa", "b"],
                     ["x]y"], ["swift", "build", "-c", "release"], ["make", "it so"]]
        for pattern in patterns {
            let routes = [Route(match: pattern, recipe: "r")]
            for argv in lines {
                XCTAssertEqual(DelegateRouting.recipe(for: argv, in: [WireRoute(match: pattern, recipe: "r")]),
                               RouteMatcher(routes: routes).match(argv)?.recipe, "\(pattern) vs \(argv)")
            }
        }
    }
}
