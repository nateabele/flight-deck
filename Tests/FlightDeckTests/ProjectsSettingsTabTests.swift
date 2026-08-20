import XCTest
@testable import FlightDeck

@MainActor
final class ProjectsSettingsTabTests: XCTestCase {
    /// With `<Use global settings>` selected the editor is hidden, but the overrides are still
    /// in force — so the pane has to say so, or they are invisible and active.
    func testHiddenOverridesAreNamed() {
        let settings = ProjectSettings(options: [.codex: .codex(CodexThreadOptions(sandbox: "read-only"))])
        XCTAssertEqual(
            ProjectsSettingsTab.hiddenOverrideSummary(settings, excluding: nil),
            "Codex has project overrides. Select Codex to edit them."
        )
    }

    func testTheEditedAgentIsNotListedAsHidden() {
        let settings = ProjectSettings(options: [.codex: .codex(CodexThreadOptions(sandbox: "read-only"))])
        XCTAssertNil(ProjectsSettingsTab.hiddenOverrideSummary(settings, excluding: .codex))
    }

    func testEmptyOptionsAreNotAnOverride() {
        XCTAssertNil(ProjectsSettingsTab.hiddenOverrideSummary(
            ProjectSettings(options: [.codex: .codex(CodexThreadOptions())]), excluding: nil
        ))
    }
}
