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

    // MARK: - The codex copy

    func testInstallPutsTheSameBytesInTheCodexHomeSkillsDirectory() throws {
        let source = try bundledSkill()
        XCTAssertTrue(try CodexDelegateSkill.install(from: source, codexHome: tempHome))
        let target = tempHome.appendingPathComponent("skills/flightdeck-delegate/SKILL.md")
        XCTAssertEqual(CodexDelegateSkill.destination(codexHome: tempHome), target)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source),
                       "codex must read byte-for-byte what claude reads")
    }

    func testInstallLeavesACurrentCopyAlone() throws {
        let source = try bundledSkill()
        try CodexDelegateSkill.install(from: source, codexHome: tempHome)
        XCTAssertFalse(try CodexDelegateSkill.install(from: source, codexHome: tempHome))
    }

    func testInstallReplacesAStaleCopy() throws {
        let source = try bundledSkill()
        let target = CodexDelegateSkill.destination(codexHome: tempHome)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("an older build's text".utf8).write(to: target)
        XCTAssertTrue(try CodexDelegateSkill.install(from: source, codexHome: tempHome),
                      "an app update must reach codex, not be skipped because a file exists")
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source))
    }

    func testInstallNeverTouchesTheUsersOwnDelegateSkill() throws {
        let mine = tempHome.appendingPathComponent("skills/delegate/SKILL.md")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("the user's own".utf8).write(to: mine)
        try CodexDelegateSkill.install(from: try bundledSkill(), codexHome: tempHome)
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "the user's own")
    }

    /// Under xctest `Bundle.main` is the test tool, which carries no plugin, so the production
    /// entry point must write nothing. That is also what keeps a test run that reaches
    /// `CodexProcessTransport.start()` out of the developer's real `~/.codex`.
    func testInstallBundledWritesNothingWithoutAPluginInTheBundle() {
        CodexDelegateSkill.installBundled(codexHome: tempHome, bundle: .main)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CodexDelegateSkill.destination(codexHome: tempHome).path))
    }

    func testInstallBundledCopiesFromAPluginBundle() {
        CodexDelegateSkill.installBundled(codexHome: tempHome, bundle: Bundle(for: Self.self))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CodexDelegateSkill.destination(codexHome: tempHome).path))
    }
}
