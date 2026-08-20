// Tests/FlightDeckTests/ProjectSettingsTests.swift
import XCTest
@testable import FlightDeck

final class ProjectSettingsTests: XCTestCase {
    /// The reason for the `CodingKeyRepresentable` conformance: without it Swift encodes an
    /// enum-keyed dictionary as a flat alternating array, which is unreadable on disk and
    /// breaks the "raw values are a storage format" contract on `AgentID`.
    func testAgentKeyedDictionariesEncodeAsObjects() throws {
        let settings = ProjectSettings(defaultAgent: .codex, accounts: [.claude: UUID()], options: [:])
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(settings)
        ) as? [String: Any]
        XCTAssertNotNil((json?["accounts"] as? [String: Any])?["claude"])
    }

    func testEmptinessIgnoresPresentButEmptyOptions() {
        var settings = ProjectSettings()
        XCTAssertTrue(settings.isEmpty)
        settings.options[.claude] = .claude(FlagSet())
        XCTAssertTrue(settings.isEmpty, "an empty FlagSet is not an override")
        settings.options[.claude] = .claude(FlagSet(values: ["--model": .value("opus")]))
        XCTAssertFalse(settings.isEmpty)
    }

    func testEmptinessSeesADefaultAgentAndAnAccount() {
        XCTAssertFalse(ProjectSettings(defaultAgent: .claude).isEmpty)
        XCTAssertFalse(ProjectSettings(accounts: [.codex: UUID()]).isEmpty)
    }

    func testCodexMergeInheritsNilFieldsAndOverridesSetOnes() {
        let global = CodexThreadOptions(model: "gpt-5", sandbox: "read-only", addDirs: ["/g"])
        let project = CodexThreadOptions(sandbox: "workspace-write")
        let merged = CodexThreadOptions.merge(global: global, project: project)
        XCTAssertEqual(merged.model, "gpt-5")
        XCTAssertEqual(merged.sandbox, "workspace-write")
        XCTAssertEqual(merged.addDirs, ["/g"], "an empty project list inherits rather than clearing")
    }

    func testCodexMergeReplacesAddDirsWhenTheProjectSetsThem() {
        let merged = CodexThreadOptions.merge(
            global: CodexThreadOptions(addDirs: ["/g"]), project: CodexThreadOptions(addDirs: ["/p"])
        )
        XCTAssertEqual(merged.addDirs, ["/p"])
    }
}
