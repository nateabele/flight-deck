import XCTest
import IntakeKit
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

    // MARK: The account picker (unify brief R8)

    private func account(_ name: String, _ agent: AgentID = .claude) -> AgentAccount {
        AgentAccount(agent: agent, displayName: name, home: URL(fileURLWithPath: "/tmp/fd-projects/\(name)"))
    }

    /// Default first (naming the account it means), then the agent's accounts, then its pools —
    /// the default pool of unpooled accounts included, local pools and other agents' rows not.
    func testThePickerOffersDefaultEachAccountAndEachPoolOfTheAgent() {
        let a = account("A"), b = account("B"), c = account("C"), x = account("X", .codex)
        let list = AccountList(entries: [
            .account(a), .account(x),
            .pool(AccountPool(id: "team", label: "Team", agent: .claude, members: [b, c])),
            .pool(AccountPool(id: "llm", label: "Box", agent: .claude, kind: .local)),
            .pool(AccountPool(id: "ct", label: "Codex team", agent: .codex, members: [])),
        ])
        let options = ProjectsSettingsTab.accountOptions(for: .claude, in: list)
        XCTAssertEqual(options.map(\.title), ["Default (A)", "A", "B", "C", "Team", "Claude default"])
        XCTAssertEqual(options.map(\.value), [nil, .account(a.id), .account(b.id), .account(c.id),
                                               .pool("team"), .pool("claude-default")])
        XCTAssertEqual(options.map(\.isPool), [false, false, false, false, true, true])
    }

    /// A pool assignment shows as itself, not as "Default".
    func testAnAssignedPoolIsOneOfTheOptions() {
        let b = account("B")
        let list = AccountList(entries: [.pool(AccountPool(id: "team", label: "Team", agent: .claude, members: [b]))])
        XCTAssertTrue(ProjectsSettingsTab.accountOptions(for: .claude, in: list).contains { $0.value == .pool("team") })
    }

    /// One account and no pool is no choice at all, so the section is hidden — unless the project
    /// already names something, which must stay visible to be undone.
    func testThePickerShowsOnlyWhenThereIsAChoice() {
        let one = AccountList(entries: [.account(account("A"))])
        XCTAssertFalse(ProjectsSettingsTab.showsAccountPicker(for: .claude, in: one, assigned: nil))
        XCTAssertTrue(ProjectsSettingsTab.showsAccountPicker(for: .claude, in: one, assigned: .pool("gone")))
        let pooled = AccountList(entries: [.pool(AccountPool(id: "t", label: "T", agent: .claude, members: [account("A")]))])
        XCTAssertTrue(ProjectsSettingsTab.showsAccountPicker(for: .claude, in: pooled, assigned: nil))
    }
}
