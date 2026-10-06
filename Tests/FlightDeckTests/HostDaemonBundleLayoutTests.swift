import XCTest

/// The BUILT app's hostd packaging, read off disk. Nothing here launches anything.
///
/// hostd runs an `NSApplication` (the "don't touch" panel, `ScreenPanel`). A bare executable
/// at `Flight Deck.app/Contents/MacOS/flightdeck-hostd` has no bundle of its own, so that
/// `NSApplication` checks in with LaunchServices as the enclosing app,
/// `dev.flightdeck.FlightDeck`. From then on `open -a "Flight Deck"`, a Finder double-click or
/// a Dock click only activates hostd, and the real app never starts — observed live on a host
/// Mac (`launchservicesd CHECKIN … dev.flightdeck.FlightDeck` from hostd's pid, and
/// runningboard handing hostd the frontmost assertion). These assertions pin the fix: hostd
/// lives in its own helper bundle with its own identifier.
///
/// The test bundle is built into `Flight Deck.app/Contents/PlugIns/`, so the app it inspects
/// is the one this very build produced, not whatever is installed in /Applications.
final class HostDaemonBundleLayoutTests: XCTestCase {
    private static let helperPath = "Contents/Library/LoginItems/Flight Deck Host.app"
    private static let agentPlistPath = "Contents/Library/LaunchAgents/dev.flightdeck.hostd.plist"

    private func builtApp() throws -> URL {
        var url = Bundle(for: type(of: self)).bundleURL
        while url.pathExtension != "app" {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else {
                throw XCTSkip("test bundle is not inside a built app: \(Bundle(for: type(of: self)).bundleURL.path)")
            }
            url = parent
        }
        return url
    }

    private func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "\(url.path) is not a dictionary plist")
    }

    /// Every `@rpath/…` library the helper links must resolve through one of its own `LC_RPATH`
    /// entries, the way dyld would. Moving hostd into `LoginItems/<helper>.app` changed how many
    /// levels up the app's `Contents/Frameworks` is; a rpath one `..` short shipped and made dyld
    /// refuse to start hostd on a real host (`Library not loaded: @rpath/FleetKit.framework…`,
    /// `last exit reason = OS_REASON_DYLD`), which the layout checks above could not see.
    func testEveryRpathLibraryOfTheHelperResolvesInsideTheApp() throws {
        let app = try builtApp()
        let exe = app.appendingPathComponent(Self.helperPath)
            .appendingPathComponent("Contents/MacOS/flightdeck-hostd")
        let exeDir = exe.deletingLastPathComponent().path

        // Follow @rpath dependencies transitively, as dyld does: a Debug build links the helper
        // to its own `flightdeck-hostd.debug.dylib` first, and FleetKit hangs off that, so a
        // one-level check passes a Debug build whose Release twin cannot start.
        func rpaths(of image: String) throws -> [String] {
            try otool(["-l", image]).components(separatedBy: "\n").compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("path ") else { return nil }
                return String(t.dropFirst(5).split(separator: " ").first ?? "")
            }
            .map {
                $0.replacingOccurrences(of: "@executable_path", with: exeDir)
                    .replacingOccurrences(of: "@loader_path", with: (image as NSString).deletingLastPathComponent)
            }
        }
        func rpathDeps(of image: String) throws -> [String] {
            try otool(["-L", image]).components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("@rpath/") }
                .map { String($0.dropFirst("@rpath/".count).split(separator: " ").first ?? "") }
        }

        var searched = try rpaths(of: exe.path)
        var queue = try rpathDeps(of: exe.path)
        var seen = Set<String>()
        var sawFleetKit = false
        while let dep = queue.popLast() {
            guard seen.insert(dep).inserted else { continue }
            let resolved = searched.lazy.map { "\($0)/\(dep)" }
                .first { FileManager.default.fileExists(atPath: $0) }
            guard let resolved else {
                XCTFail("@rpath/\(dep) resolves through none of \(searched)")
                continue
            }
            if dep.hasPrefix("FleetKit.framework") { sawFleetKit = true }
            searched += try rpaths(of: resolved)
            queue += try rpathDeps(of: resolved)
        }
        XCTAssertTrue(sawFleetKit, "expected the helper to load FleetKit through @rpath")
    }

    private func otool(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["otool"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testHostdIsItsOwnHelperBundleWithADistinctIdentity() throws {
        let app = try builtApp()
        let helper = app.appendingPathComponent(Self.helperPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path),
                      "no helper bundle at \(helper.path)")

        let appInfo = try plist(app.appendingPathComponent("Contents/Info.plist"))
        let helperInfo = try plist(helper.appendingPathComponent("Contents/Info.plist"))
        let helperID = helperInfo["CFBundleIdentifier"] as? String
        XCTAssertEqual(helperID, "dev.flightdeck.hostd")
        XCTAssertNotEqual(helperID, appInfo["CFBundleIdentifier"] as? String)
        XCTAssertEqual(helperInfo["LSUIElement"] as? Bool, true,
                       "hostd must never get a Dock icon or a menu bar")
        XCTAssertEqual(helperInfo["CFBundleExecutable"] as? String, "flightdeck-hostd")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: helper.appendingPathComponent("Contents/MacOS/flightdeck-hostd").path))
    }

    /// The old location must be gone, not merely shadowed: a stale copy there is exactly the
    /// binary that borrowed the app's identity.
    func testNoHostdBinaryLeftInTheAppsOwnMacOSDirectory() throws {
        let stale = try builtApp().appendingPathComponent("Contents/MacOS/flightdeck-hostd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "hostd is still at \(stale.path), where it checks in as the app")
    }

    /// `SMAppService` resolves `BundleProgram` against the app bundle, so it must name the
    /// helper's executable — a path that does not exist registers fine and then never runs.
    func testLaunchAgentBundleProgramResolvesToTheHelperExecutable() throws {
        let app = try builtApp()
        let agent = try plist(app.appendingPathComponent(Self.agentPlistPath))
        let program = try XCTUnwrap(agent["BundleProgram"] as? String)
        XCTAssertFalse(program.hasPrefix("/"), "BundleProgram is bundle-relative")

        let resolved = app.appendingPathComponent(program).standardizedFileURL
        XCTAssertTrue(resolved.path.hasPrefix(app.standardizedFileURL.path + "/"),
                      "\(program) escapes the bundle")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved.path),
                      "BundleProgram \(program) is not an executable in the built app")
        XCTAssertEqual(program, Self.helperPath + "/Contents/MacOS/flightdeck-hostd")
    }
}
