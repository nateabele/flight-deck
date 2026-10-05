import CoreServices
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
        XCTAssertEqual(RouteShims.environment(["A": "1", "PATH": "/usr/bin:/bin"], prepending: dir, cli: nil),
                       ["A": "1", "PATH": "/tmp/shims/S:/usr/bin:/bin"])
        // Already first (a rebuild re-applied to the same environment): unchanged, not doubled.
        XCTAssertEqual(RouteShims.environment(["PATH": "/tmp/shims/S:/usr/bin"], prepending: dir, cli: nil)["PATH"],
                       "/tmp/shims/S:/usr/bin")
        // No PATH of its own: the inherited one, so the tab does not lose every other directory.
        XCTAssertEqual(RouteShims.environment([:], prepending: dir, cli: nil, inherited: "/usr/bin")["PATH"],
                       "/tmp/shims/S:/usr/bin")
    }

    func testEnvironmentNamesThisBuildsCLI() {
        let cli = URL(fileURLWithPath: "/Applications/Flight Deck.app/Contents/MacOS/flightdeck")
        let env = RouteShims.environment(["PATH": "/tmp/shims/S"], prepending: URL(fileURLWithPath: "/tmp/shims/S"), cli: cli)
        XCTAssertEqual(env["FLIGHTDECK_CLI"], cli.path, "set even when the PATH needed no change")
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
            // A bare `route-exec` gets a current CLI's answer to the shim's probe: a usage
            // error, exit 2, nothing done.
            let probe = "if [ \"$#\" = 1 ] && [ \"$1\" = route-exec ]; then echo 'usage: flightdeck route-exec <argv0> -- <args…>' >&2; exit 2; fi\n"
            try "#!/bin/bash\n\(probe)echo \(label)\nfor a in \"$@\"; do echo \"[$a]\"; done\necho \"PATH=$PATH\"\n"
                .write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try tool(real.appendingPathComponent("xcodebuild"), "REAL")
        if withCLI { try tool(cli.appendingPathComponent("flightdeck"), "CLI") }
        try fm.createSymbolicLink(at: shimDir.appendingPathComponent("xcodebuild"), withDestinationURL: Self.script)
        return (shimDir, [shimDir.path, cli.path, real.path, "/usr/bin", "/bin"].joined(separator: ":"))
    }

    /// A CLI from before route-exec: the real one's usage error, exit 2.
    private func oldCLI(_ url: URL) throws {
        try "#!/bin/bash\necho OLD\nif [ \"$1\" = route-exec ]; then echo 'flightdeck: unknown command \"route-exec\"' >&2; exit 2; fi\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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

    /// The tab's PATH has an older `flightdeck` first; the one named by the app wins.
    func testScriptPrefersFlightdeckCLIOverPath() throws {
        let (_, path) = try fakes(withCLI: false)
        try oldCLI(temp.appendingPathComponent("cli bin/flightdeck"))
        let current = temp.appendingPathComponent("current/flightdeck")
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\necho CURRENT \"$@\"\n".write(to: current, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: current.path)
        let output = try runShell("xcodebuild test", path: path, extra: ["FLIGHTDECK_CLI": current.path])
        XCTAssertEqual(output, "CURRENT route-exec xcodebuild -- test\n")
    }

    /// No FLIGHTDECK_CLI (a tab launched before this build): the CLI in the script's own
    /// bundle, `Contents/MacOS/flightdeck`, beats the older one on PATH.
    func testScriptPrefersTheCLIInItsOwnBundle() throws {
        let fm = FileManager.default
        let (shimDir, path) = try fakes(withCLI: false)
        try oldCLI(temp.appendingPathComponent("cli bin/flightdeck"))
        let contents = temp.appendingPathComponent("Fake.app/Contents")
        let bundled = contents.appendingPathComponent("Resources/RouteShim/flightdeck-route-shim.sh")
        try fm.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.script, to: bundled)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let sibling = contents.appendingPathComponent("MacOS/flightdeck")
        try "#!/bin/bash\necho SIBLING \"$@\"\n".write(to: sibling, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sibling.path)
        let link = shimDir.appendingPathComponent("xcodebuild")
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
        XCTAssertEqual(try runShell("xcodebuild test", path: path), "SIBLING route-exec xcodebuild -- test\n")
    }

    /// Only an old CLI is reachable: the command runs locally instead of failing.
    func testScriptRunsTheRealBinaryWhenTheCLIPredatesRouteExec() throws {
        let (_, path) = try fakes(withCLI: false)
        try oldCLI(temp.appendingPathComponent("cli bin/flightdeck"))
        let output = try runShell("xcodebuild test", path: path)
        XCTAssertTrue(output.hasPrefix("REAL\n[test]\n"), output)
    }

    private func stubCLI(_ body: String) throws {
        let url = temp.appendingPathComponent("cli bin/flightdeck")
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A CLI on PATH that crashes on the probe would crash on the real call too; execing it
    /// anyway made the command unrunnable.
    func testScriptRunsTheRealBinaryWhenTheCLICrashes() throws {
        let (_, path) = try fakes(withCLI: false)
        try stubCLI("kill -SEGV $$")
        XCTAssertTrue(try runShell("xcodebuild test", path: path).hasPrefix("REAL\n[test]\n"))
    }

    /// Exit 2 with no usage text is not a current CLI either.
    func testScriptRunsTheRealBinaryWhenTheProbeSaysNothing() throws {
        let (_, path) = try fakes(withCLI: false)
        try stubCLI("exit 2")
        XCTAssertTrue(try runShell("xcodebuild test", path: path).hasPrefix("REAL\n[test]\n"))
    }

    /// A probe that hangs is killed, with its children, after 2 seconds. Killing only the CLI
    /// left its `sleep` holding the capture pipe, and the shim waited the full 30 seconds.
    func testScriptRunsTheRealBinaryWhenTheProbeHangs() throws {
        let (_, path) = try fakes(withCLI: false)
        try stubCLI("[ \"$#\" = 1 ] && sleep 30\necho HUNG \"$@\"")
        let start = Date()
        XCTAssertTrue(try runShell("xcodebuild test", path: path).hasPrefix("REAL\n[test]\n"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    /// FLIGHTDECK_CLI is this build's own CLI, so it is not probed: one process, not two.
    func testTrustedCLIIsNotProbed() throws {
        let (_, path) = try fakes(withCLI: false)
        let log = temp.appendingPathComponent("calls.log")
        let cli = temp.appendingPathComponent("trusted-cli")
        try "#!/bin/bash\necho \"$*\" >> '\(log.path)'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        _ = try runShell("xcodebuild test", path: path, extra: ["FLIGHTDECK_CLI": cli.path])
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "route-exec xcodebuild -- test\n")
    }

    /// A child that rebuilt PATH with the shims on it must not route again.
    func testRouteDepthGuardRunsTheRealBinary() throws {
        let (_, path) = try fakes(withCLI: true)
        XCTAssertTrue(try runShell("xcodebuild test", path: path, extra: ["FLIGHTDECK_ROUTE_DEPTH": "1"])
            .hasPrefix("REAL\n"))
        // And the CLI is handed depth 1, so its fall-through's children inherit the guard.
        let probe = temp.appendingPathComponent("depth-cli")
        try "#!/bin/bash\necho DEPTH=$FLIGHTDECK_ROUTE_DEPTH\n".write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        XCTAssertEqual(try runShell("xcodebuild test", path: path, extra: ["FLIGHTDECK_CLI": probe.path]), "DEPTH=1\n")
    }

    /// The shim dir spelled differently on PATH (trailing slash, a symlinked parent) is still
    /// the shim dir; a string compare missed it and the fall-through found the shim again.
    func testScriptStripsTheShimDirHoweverItIsSpelled() throws {
        let (shimDir, path) = try fakes(withCLI: false)
        let alias = temp.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shimDir.deletingLastPathComponent())
        let spelled = path.replacingOccurrences(of: shimDir.path + ":", with: shimDir.path + "/:")
            + ":" + alias.appendingPathComponent("S").path
        let output = try runShell("xcodebuild -version", path: spelled)
        XCTAssertTrue(output.hasPrefix("REAL\n"), output)
        let pathLine = output.split(separator: "\n").first { $0.hasPrefix("PATH=") } ?? ""
        XCTAssertFalse(pathLine.contains(shimDir.path), output)
        XCTAssertFalse(pathLine.contains(alias.path), output)
    }

    // MARK: - Watching delegate.toml

    func testDroppedEventsAndRootChangesForceARebuild() {
        XCTAssertTrue(RouteShimWatcher.mustRescan(FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)))
        XCTAssertTrue(RouteShimWatcher.mustRescan(FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)))
        XCTAssertFalse(RouteShimWatcher.mustRescan(FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)))
    }

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
