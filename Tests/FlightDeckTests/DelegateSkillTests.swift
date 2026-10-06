import XCTest
@testable import FlightDeck

/// The `delegate` skill is one file shipped to two agents: claude reads it through the bundled
/// plugin and codex reads a copy in its home. These guard the text itself, which is data and
/// would otherwise go stale silently, and the codex copy.
final class DelegateSkillTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("DelegateSkillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    private func bundledSkill() throws -> URL {
        try XCTUnwrap(
            CodexDelegateSkill.bundledSource(bundle: Bundle(for: Self.self)),
            "skills/delegate/SKILL.md must ride inside the ClaudePlugin folder reference"
        )
    }

    // MARK: - The text

    func testSkillIsNamedDelegateAndDescribesWhenToUseIt() throws {
        let text = try String(contentsOf: try bundledSkill(), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: delegate\ndescription: "),
                      "both loaders read the frontmatter; without a description neither offers the skill")
    }

    /// Spec §9: the skill is static and points at the live listings, so pairing a host or
    /// adding a recipe never makes it stale.
    func testSkillSendsTheAgentToTheLiveListings() throws {
        let text = try String(contentsOf: try bundledSkill(), encoding: .utf8)
        for command in ["flightdeck host ls", "flightdeck host info", "flightdeck recipe ls",
                        "flightdeck run --help", "flightdeck exec", "flightdeck wait",
                        "flightdeck diff", "flightdeck apply", "flightdeck up", "flightdeck down",
                        "flightdeck recipe add", "125"] {
            XCTAssertTrue(text.contains(command), "the skill must cover `\(command)`")
        }
    }

    /// Every host and recipe in the text is a placeholder. A concrete name would be
    /// wrong for every user but one, and would go stale the moment that one re-pairs.
    func testSkillNeverNamesAHostOrRecipe() throws {
        let text = try String(contentsOf: try bundledSkill(), encoding: .utf8)
        for pattern in [#"--on [^<]"#, #"flightdeck (run|up) [a-z]"#, #"\[recipe\."#] {
            XCTAssertNil(text.range(of: pattern, options: .regularExpression),
                         "`\(pattern)` would hard-code a host or recipe")
        }
    }

    /// 125 is shared: the remote command may exit 125 itself, so only 125 plus a `flightdeck:`
    /// line is a delegation failure. An agent told "125 means nothing ran" would treat a real
    /// remote failure as a harmless retry.
    func testSkillReadsExitCodesTheWayTheCLIWritesThem() throws {
        let text = try String(contentsOf: try bundledSkill(), encoding: .utf8)
        XCTAssertFalse(text.contains("nothing ran"))
        for phrase in ["125 with a stderr line starting `flightdeck:`",
                       "A 125 without that line is the remote command's own exit code",
                       "exits with the run's own exit code",
                       "`include` list in `.flightdeck/delegate.toml`",
                       #"apply = "auto""#] {
            XCTAssertTrue(text.contains(phrase), "the skill must say: \(phrase)")
        }
    }

    // MARK: - The codex copy

    private var target: URL { CodexDelegateSkill.destination(codexHome: tempHome) }
    private var marker: URL { CodexDelegateSkill.sidecar(codexHome: tempHome) }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func install() throws -> CodexDelegateSkill.Outcome {
        try CodexDelegateSkill.install(from: try bundledSkill(), codexHome: tempHome)
    }

    func testInstallPutsTheSameBytesInTheCodexHomeSkillsDirectory() throws {
        XCTAssertEqual(try install(), .installed)
        XCTAssertEqual(target, tempHome.appendingPathComponent("skills/flightdeck-delegate/SKILL.md"))
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: try bundledSkill()),
                       "codex must read byte-for-byte what claude reads")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8),
                       CodexDelegateSkill.digest(try Data(contentsOf: target)) + "\n")
    }

    func testInstallLeavesACurrentCopyAlone() throws {
        _ = try install()
        XCTAssertEqual(try install(), .current)
    }

    /// Our own older text, untouched by the user since we wrote it, is refreshed. An app
    /// update must reach codex, not be skipped because a file exists.
    func testInstallRefreshesOurStaleCopy() throws {
        let old = "an older build's text"
        try put(old, at: target)
        try put(CodexDelegateSkill.digest(Data(old.utf8)), at: marker)
        XCTAssertEqual(try install(), .refreshed)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: try bundledSkill()))
    }

    func testInstallLeavesAUserEditedCopyAlone() throws {
        _ = try install()
        try put("the user's own edit", at: target)
        XCTAssertEqual(try install(), .userEdited)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "the user's own edit")
    }

    func testInstallNeverRecreatesACopyTheUserDeleted() throws {
        _ = try install()
        try FileManager.default.removeItem(at: target)
        XCTAssertEqual(try install(), .userDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// No sidecar means Flight Deck never wrote this file, so it is the user's.
    func testInstallLeavesAnUnmanagedFileAlone() throws {
        try put("written by hand", at: target)
        XCTAssertEqual(try install(), .userOwned)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "written by hand")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// An unmanaged file that is byte-for-byte ours is adopted. This also covers a crash
    /// between writing SKILL.md and its sidecar.
    func testInstallAdoptsAnUnmanagedFileThatIsExactlyOurs() throws {
        try put(try String(contentsOf: try bundledSkill(), encoding: .utf8), at: target)
        XCTAssertEqual(try install(), .adopted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try put("edited later", at: target)
        XCTAssertEqual(try install(), .userEdited, "once adopted, an edit still sticks")
    }

    func testInstallNeverTouchesTheUsersOwnDelegateSkill() throws {
        let mine = tempHome.appendingPathComponent("skills/delegate/SKILL.md")
        try put("the user's own", at: mine)
        _ = try install()
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "the user's own")
    }

    // MARK: - Uninstall

    func testUninstallRemovesOurCopyAndItsDirectory() throws {
        _ = try install()
        XCTAssertTrue(try CodexDelegateSkill.uninstall(home: tempHome))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
    }

    func testUninstallKeepsAUserEditedCopy() throws {
        _ = try install()
        try put("the user's own edit", at: target)
        XCTAssertFalse(try CodexDelegateSkill.uninstall(home: tempHome))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "the user's own edit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUninstallKeepsAnUnmanagedFile() throws {
        try put("written by hand", at: target)
        XCTAssertFalse(try CodexDelegateSkill.uninstall(home: tempHome))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testUninstallClearsALoneSidecarSoALaterInstallStartsFresh() throws {
        _ = try install()
        try FileManager.default.removeItem(at: target)
        XCTAssertTrue(try CodexDelegateSkill.uninstall(home: tempHome))
        XCTAssertEqual(try install(), .installed)
    }

    // MARK: - The production entry point

    /// Under xctest `Bundle.main` is the test tool, which carries no plugin, so the production
    /// entry point must write nothing. That is also what keeps a test run that reaches
    /// `SessionStore.startCodex` out of the developer's real `~/.codex`.
    func testInstallBundledWritesNothingWithoutAPluginInTheBundle() async {
        await CodexDelegateSkill.installBundledOffMainActor(codexHome: tempHome, bundle: .main, debugBuild: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testInstallBundledCopiesFromAPluginBundle() async {
        await CodexDelegateSkill.installBundledOffMainActor(
            codexHome: tempHome, bundle: Bundle(for: Self.self), debugBuild: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    /// A Debug build never writes into a codex home: it is the user's real one, shared with
    /// their installed Flight Deck.
    func testADebugBuildInstallsNothing() async {
        await CodexDelegateSkill.installBundledOffMainActor(
            codexHome: tempHome, bundle: Bundle(for: Self.self), debugBuild: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// The copy runs off the main thread, so `startCodex` never blocks the UI on disk I/O.
    @MainActor
    func testInstallBundledRunsTheCopyOffTheMainThread() async {
        let onMain = Flag()
        await CodexDelegateSkill.installBundledOffMainActor(
            codexHome: tempHome, bundle: Bundle(for: Self.self), debugBuild: false,
            perform: { _, _ in onMain.set(Thread.isMainThread); return .current })
        XCTAssertEqual(onMain.value, false)
    }

    /// A stalled codex home (say, a hung network volume) must not wedge `startCodex`, whose
    /// task is memoized per account. The caller unblocks at the deadline.
    func testInstallBundledReturnsAtTheDeadlineWhenTheCopyStalls() async {
        let started = Date()
        await CodexDelegateSkill.installBundledOffMainActor(
            codexHome: tempHome, bundle: Bundle(for: Self.self), timeoutSeconds: 0.2, debugBuild: false,
            perform: { _, _ in Thread.sleep(forTimeInterval: 3); return .current })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}

/// A thread-safe box the off-main test writes into from the copy's own thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
}
