import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// What a heatmap-cell click shows: Diff vs Previous as the plan editor, the round's changes
/// drawn inline over the previous plan, and the page taken to the clicked section's first
/// change under a stand-in for the pinned block. A changed paragraph, a changed table and a
/// removed section, light and dark. Skipped unless `FD_PLANNING_RENDER_DIR` names an output
/// directory; the PNGs are for judging by eye.
@MainActor
final class DiffVsPreviousRenderTests: XCTestCase {
    private static let previous = """
    # Per-project font size

    ## 1. Goals

    Each project can override the terminal font size. The setting is stored per project and read when a surface is created, so a change applies to new terminals only.

    Existing terminals keep the size they were opened with until they are restarted by hand.

    ## 2. Settings storage

    | Surface | Reads | When |
    |---|---|---|
    | Terminal | fontSize | init |
    | Sidebar preview | none | never |
    | Quick terminal | fontSize | first show |

    The global preference is the fallback when a project has no override.

    ## 3. Migration

    Migrate existing sessions lazily, the first time a project's settings are opened. Nothing is rewritten on launch.

    ## 4. Testing

    Pin the fallback with a unit test, and the per-project override with a second.

    ## 5. Rollout

    Ship behind no flag; the setting is inert until someone changes it.
    """

    private static let current = previous
        .replacingOccurrences(of: "so a change applies to new terminals only.", with: "so a change applies to new terminals and, after a restart, to existing ones.")
        .replacingOccurrences(of: "| Terminal | fontSize | init |", with: "| Terminal | fontSize | surface init |")
        .replacingOccurrences(of: "| Sidebar preview | none | never |\n", with: "")
        .replacingOccurrences(of: "\n\n## 3. Migration\n\nMigrate existing sessions lazily, the first time a project's settings are opened. Nothing is rewritten on launch.", with: "")

    func testRenderHeatmapClickResults() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let tape = Tape(checkpoints: [Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: date),
                                      Checkpoint(id: 2, parent: 1, stage: .refine, round: 1, major: false, createdAt: date)],
                        target: .none, status: .paused)
        let load: (Int, String) -> Data? = { id, file in file == "plan.md" ? Data((id == 1 ? Self.previous : Self.current).utf8) : nil }
        let out = URL(fileURLWithPath: dir)
        let covered: CGFloat = 90
        for (section, name) in [("## 1. Goals", "paragraph"), ("## 2. Settings storage", "table"), ("## 3. Migration", "removed")] {
            for (appearance, tone) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let page = ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 20)
                        PlanSection(intakeID: UUID(), tape: tape, loadFile: load, onSend: { _ in }, selection: .constant(2))
                            .focus(PlanFocus(checkpoint: 2, section: section, seq: 1))
                            .padding(.horizontal, 24)
                        Color.clear.frame(height: 600)
                    }
                    .environment(\.pageObscuredTop, covered)
                }
                .overlay(alignment: .top) {
                    Text("pinned block").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: covered)
                        .background(.regularMaterial)
                }
                try PlanningRender.write(page, size: NSSize(width: 900, height: 620),
                                         to: out.appendingPathComponent("diff-\(name)-\(tone).png"), appearance: appearance)
            }
        }
    }
}
