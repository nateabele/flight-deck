import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The Rounds inspector fits its column. Every control in an agent's row was `.fixedSize()`, so a
/// three-agent Polisher rotation (label, glyph, "Claude > Opus 5.5 (latest)", effort, move/remove
/// buttons) and a "Project default — …" account picker came out wider than the inspector, and the
/// inspector clipped the right-hand end of each row.
final class RoundConfigEditorFitTests: XCTestCase {
    /// `.inspectorColumnWidth(min: 300)` in `IntakeDetailView`, less the 16 pt it pads the editor
    /// with on each side.
    static let narrowest: CGFloat = 268

    @MainActor
    func testThePolishStageFitsTheNarrowestInspector() throws {
        let (editor, _) = try Self.polishEditor()
        let size = NSHostingController(rootView: editor)
            .sizeThatFits(in: CGSize(width: Self.narrowest, height: 10_000))
        XCTAssertLessThanOrEqual(size.width, Self.narrowest,
                                 "the Rounds inspector is wider than its column, so its right-hand controls are clipped")
    }

    /// Full plan with the polish stage open: three polishers taking turns, one of them on an
    /// account picker whose default names a pool.
    @MainActor
    static func polishEditor() throws -> (RoundConfigEditor, RoundConfig) {
        var config = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        config.customized = true
        let claude = ModelChoice(agent: .claude, model: "claude-opus-5-5-with-a-long-model-id", effort: "high")
        let codex = AvailableModels.defaults.codex!
        config.polisher = claude
        config.polishers = [claude, codex, claude]
        let accounts: [AgentID: AccountMenu] = [
            .claude: AccountMenu(projectDefault: "Field pool with a long name",
                                 options: [.init(choice: .account(UUID()), title: "Work", isPool: false)],
                                 offersChoice: true),
            .codex: AccountMenu(projectDefault: "someone@example.com"),
        ]
        let editor = RoundConfigEditor(preset: .fullPlan, config: .constant(config), available: .defaults,
                                       accounts: accounts,
                                       selection: .constant(RoundTimeline.Selection(section: .polish, round: nil)))
        return (editor, config)
    }
}
