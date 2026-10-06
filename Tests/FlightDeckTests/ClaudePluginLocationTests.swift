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

    /// Pinned against a hand-built literal, not `ClaudePluginLocation.buildTag`/`eventDirectory`
    /// themselves — a `.contains(buildTag)` check (or comparing the property against itself)
    /// can only catch a wrong *key*, never a wrong base directory, subpath, or tag literal.
    /// `test-unit.sh` always builds Debug, so `hook-events-debug` is the real expected leaf.
    func testDebugAndReleaseDoNotShareAnEventDirectory() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let expected = base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("hook-events-debug", isDirectory: true)
        XCTAssertEqual(
            ClaudePluginLocation.eventDirectory,
            expected,
            "a shared directory would let a debug build read the real fleet's events"
        )
    }

    func testApplyingInjectsThePluginIntoAClaudePayload() throws {
        let bundle = Bundle(for: Self.self)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let out = ClaudePluginLocation.applying(to: .claude(FlagSet()), bundle: bundle, pluginDestination: tempDir)
        guard case .claude(let flags) = out, case .list(let items)? = flags.values["--plugin-dir"] else {
            return XCTFail("expected a claude payload carrying --plugin-dir")
        }
        // The behavior changed on purpose: claude runs the owned copy under Application Support,
        // not the signed bundle. This test uses a temp dir, not materializedDirectory, so it is
        // hermetic and does not mutate the developer's real Application Support folder.
        XCTAssertEqual(items, [tempDir.path])
    }

    func testApplyingLeavesACodexPayloadUntouched() {
        let options = AgentOptions.codex(CodexThreadOptions())
        XCTAssertEqual(
            ClaudePluginLocation.applying(to: options, bundle: Bundle(for: Self.self)),
            options
        )
    }

    func testApplyingLeavesAClaudePayloadUntouchedWithoutTheBundledPlugin() {
        let options = AgentOptions.claude(FlagSet())
        XCTAssertEqual(
            ClaudePluginLocation.applying(to: options, bundle: Bundle(for: NSString.self)),
            options
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
