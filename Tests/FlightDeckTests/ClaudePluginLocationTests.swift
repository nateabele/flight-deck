import XCTest
@testable import FlightDeck

final class ClaudePluginLocationTests: XCTestCase {
    func testFindsTheBundledPluginDirectory() throws {
        let url = try XCTUnwrap(ClaudePluginLocation.directory(bundle: Bundle(for: Self.self)))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("hooks/hooks.json").path
            )
        )
    }

    /// Under `xctest`, `Bundle.main` is the test runner, not the app — so a hard-coded
    /// `Bundle.main` lookup would silently return nil in the suite and pass anyway.
    func testAnswersNilForABundleWithoutThePlugin() {
        XCTAssertNil(ClaudePluginLocation.directory(bundle: Bundle(for: NSString.self)))
    }

    func testDebugAndReleaseDoNotShareAnEventDirectory() {
        XCTAssertTrue(
            ClaudePluginLocation.eventDirectory.path.contains(ClaudePluginLocation.buildTag),
            "a shared directory would let a debug build read the real fleet's events"
        )
    }

    func testInjectingThePluginFlagPreservesUserEntries() {
        var flags = FlagSet()
        flags.values["--plugin-dir"] = .list(["/user/one"])
        let out = ClaudePluginLocation.injecting(into: flags, pluginDirectory: URL(fileURLWithPath: "/app/ClaudePlugin"))
        guard case .list(let items)? = out.values["--plugin-dir"] else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items, ["/user/one", "/app/ClaudePlugin"])
    }

    func testInjectingIsIdempotent() {
        let dir = URL(fileURLWithPath: "/app/ClaudePlugin")
        let once = ClaudePluginLocation.injecting(into: FlagSet(), pluginDirectory: dir)
        let twice = ClaudePluginLocation.injecting(into: once, pluginDirectory: dir)
        guard case .list(let items)? = twice.values["--plugin-dir"] else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items, ["/app/ClaudePlugin"], "a resume must not accumulate duplicates")
    }
}
