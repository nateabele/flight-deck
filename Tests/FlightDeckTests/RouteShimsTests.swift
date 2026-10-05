import HostKit
import XCTest
@testable import FlightDeck

final class RouteShimsTests: XCTestCase {
    /// The script as checked in. `Bundle.main` under `xctest` is the xctest tool, not the app,
    /// so the bundled copy is not reachable from here; the source file is the same bytes.
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/RouteShim/flightdeck-route-shim.sh")

    /// A space in the path on purpose: the real shim directory lives under
    /// "Application Support/Flight Deck", and an unquoted expansion in the script would split it.
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("route shims \(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func project(_ toml: String?) throws -> URL {
        let root = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let toml {
            let file = DelegateConfigParser.fileURL(projectRoot: root)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try toml.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func shims() -> RouteShims {
        RouteShims(root: temp.appendingPathComponent("shims"), script: Self.script)
    }

    private func installed(_ dir: URL) throws -> [String: String] {
        let fm = FileManager.default
        var links: [String: String] = [:]
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            links[name] = try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(name).path)
        }
        return links
    }

    private static let twoRoutes = """
    [recipe.ui]
    run = "xcodebuild test"
    [recipe.build]
    run = "make"
    [[route]]
    match = "xcodebuild test *"
    recipe = "ui"
    [[route]]
    match = "xcodebuild build*"
    recipe = "ui"
    [[route]]
    match = "make *"
    recipe = "build"
    """

    // MARK: - The directory

    func testRebuildLinksOneShimPerRoutedCommand() throws {
        let session = UUID()
        let shims = shims()
        let names = shims.rebuild(session: session, projectRoot: try project(Self.twoRoutes))
        XCTAssertEqual(names, ["make", "xcodebuild"])
        XCTAssertEqual(try installed(shims.directory(for: session)),
                       ["make": Self.script.path, "xcodebuild": Self.script.path])
    }

    func testRebuildDropsShimsForRoutesThatAreGone() throws {
        let session = UUID()
        let shims = shims()
        let root = try project(Self.twoRoutes)
        shims.rebuild(session: session, projectRoot: root)
        _ = try project("""
        [recipe.build]
        run = "make"
        [[route]]
        match = "make *"
        recipe = "build"
        """)
        XCTAssertEqual(shims.rebuild(session: session, projectRoot: root), ["make"])
        XCTAssertEqual(Array(try installed(shims.directory(for: session)).keys), ["make"])
    }

    /// Mid-edit, the file is often briefly invalid. Keeping the shims means the CLI still sees
    /// the command and can say what is wrong, instead of the command silently running locally.
    func testAnUnparseableConfigLeavesTheShimsAlone() throws {
        let session = UUID()
        let shims = shims()
        let root = try project(Self.twoRoutes)
        shims.rebuild(session: session, projectRoot: root)
        _ = try project("[[route]\nmatch = ")
        XCTAssertNil(shims.rebuild(session: session, projectRoot: root))
        XCTAssertEqual(Set(try installed(shims.directory(for: session)).keys), ["make", "xcodebuild"])
    }

    /// The directory exists even with nothing to route, so a `delegate.toml` added later only
    /// has to populate a directory the tab's PATH already names.
    func testNoConfigMeansAnEmptyDirectory() throws {
        let session = UUID()
        let shims = shims()
        XCTAssertEqual(shims.rebuild(session: session, projectRoot: try project(nil)), [])
        XCTAssertEqual(try installed(shims.directory(for: session)), [:])
    }

    func testRemoveDeletesTheSessionsDirectoryOnly() throws {
        let shims = shims()
        let (a, b) = (UUID(), UUID())
        let root = try project(Self.twoRoutes)
        shims.rebuild(session: a, projectRoot: root)
        shims.rebuild(session: b, projectRoot: root)
        shims.remove(session: a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shims.directory(for: a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shims.directory(for: b).path))
    }

    func testEnvironmentPutsTheShimDirectoryFirstOnce() {
        let dir = URL(fileURLWithPath: "/tmp/shims/S")
        XCTAssertEqual(RouteShims.environment(["A": "1", "PATH": "/usr/bin:/bin"], prepending: dir),
                       ["A": "1", "PATH": "/tmp/shims/S:/usr/bin:/bin"])
        // Already first (a rebuild re-applied to the same environment): unchanged, not doubled.
        XCTAssertEqual(RouteShims.environment(["PATH": "/tmp/shims/S:/usr/bin"], prepending: dir)["PATH"],
                       "/tmp/shims/S:/usr/bin")
        // No PATH of its own: the inherited one, so the tab does not lose every other directory.
        XCTAssertEqual(RouteShims.environment([:], prepending: dir, inherited: "/usr/bin")["PATH"],
                       "/tmp/shims/S:/usr/bin")
    }

    // MARK: - The script, run by bash

    /// A fake real binary and a fake CLI, each printing its argv one per line and the PATH it
    /// saw, so the tests can tell which ran, with what, and whether the shim dir was stripped.
    private func fakes(withCLI: Bool) throws -> (shimDir: URL, path: String) {
        let fm = FileManager.default
        let real = temp.appendingPathComponent("real bin")
        let cli = temp.appendingPathComponent("cli bin")
        let shimDir = temp.appendingPathComponent("shims/S")
        for dir in [real, cli, shimDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func tool(_ url: URL, _ label: String) throws {
            try "#!/bin/bash\necho \(label)\nfor a in \"$@\"; do echo \"[$a]\"; done\necho \"PATH=$PATH\"\n"
                .write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try tool(real.appendingPathComponent("xcodebuild"), "REAL")
        if withCLI { try tool(cli.appendingPathComponent("flightdeck"), "CLI") }
        try fm.createSymbolicLink(at: shimDir.appendingPathComponent("xcodebuild"), withDestinationURL: Self.script)
        return (shimDir, [shimDir.path, cli.path, real.path, "/usr/bin", "/bin"].joined(separator: ":"))
    }

    private func runShell(_ command: String, path: String, extra: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.environment = ["PATH": path].merging(extra) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testScriptHandsAMatchToRouteExecWithTheShimDirStripped() throws {
        let (shimDir, path) = try fakes(withCLI: true)
        let output = try runShell(#"xcodebuild test "-scheme" "Flight Deck""#, path: path)
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(6)),
                       ["CLI", "[route-exec]", "[xcodebuild]", "[--]", "[test]", "[-scheme]"], output)
        XCTAssertEqual(lines[6], "[Flight Deck]", "an argument with a space must arrive as one: \(output)")
        XCTAssertFalse(output.contains(shimDir.path), "the CLI must inherit PATH without the shims: \(output)")
    }

    func testScriptFallsThroughToTheRealBinaryWithoutTheCLI() throws {
        let (shimDir, path) = try fakes(withCLI: false)
        let output = try runShell("xcodebuild -version", path: path)
        XCTAssertTrue(output.hasPrefix("REAL\n[-version]\n"), output)
        XCTAssertFalse(output.contains(shimDir.path), output)
    }

    func testNoRouteBypassesTheCLI() throws {
        let (_, path) = try fakes(withCLI: true)
        XCTAssertTrue(try runShell("xcodebuild test", path: path, extra: ["FLIGHTDECK_NO_ROUTE": "1"])
            .hasPrefix("REAL\n[test]\n"))
        // `0` is "do not bypass", not "set, therefore bypass".
        XCTAssertTrue(try runShell("xcodebuild test", path: path, extra: ["FLIGHTDECK_NO_ROUTE": "0"])
            .hasPrefix("CLI\n"))
    }

    // MARK: - Watching delegate.toml

    func testOnlyPathsUnderDotFlightdeckCountAsAChange() {
        let root = URL(fileURLWithPath: "/p/repo")
        XCTAssertTrue(RouteShimWatcher.isConfigChange("/p/repo/.flightdeck", projectRoot: root))
        XCTAssertTrue(RouteShimWatcher.isConfigChange("/p/repo/.flightdeck/delegate.toml", projectRoot: root))
        XCTAssertFalse(RouteShimWatcher.isConfigChange("/p/repo/.flightdeckx/delegate.toml", projectRoot: root))
        XCTAssertFalse(RouteShimWatcher.isConfigChange("/p/repo/build/out.o", projectRoot: root))
        XCTAssertFalse(RouteShimWatcher.isConfigChange("/p/repo/sub/.flightdeck/delegate.toml", projectRoot: root))
    }

    /// The live path: FSEvents on a project with no `.flightdeck/` yet, which is the case a
    /// watch on `.flightdeck/` itself misses (FSEvents reports nothing for a path that does not
    /// exist when the stream starts — measured, not assumed).
    @MainActor
    func testWatcherFiresWhenDelegateTomlIsCreated() async throws {
        let root = try project(nil)
        let fired = expectation(description: "onChange")
        fired.assertForOverFulfill = false
        let watcher = try XCTUnwrap(RouteShimWatcher(projectRoot: root, latency: 0.05) { fired.fulfill() })
        defer { watcher.stop() }
        _ = try project(Self.twoRoutes)
        await fulfillment(of: [fired], timeout: 20)
    }
}
