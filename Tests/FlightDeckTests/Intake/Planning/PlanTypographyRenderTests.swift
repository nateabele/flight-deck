import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The plan's type as pictures, for design review: a realistic section (heading, paragraphs, a
/// list, a table, a code block, a quote) in the editor at its usual width, light and dark, with
/// the caret out of the list and in it; and the intake composer's Markdown box inline and
/// expanded. Skipped unless `FD_PLAN_TYPE_RENDER_DIR` names an output directory. Pictures, not
/// assertions — the metrics are asserted in `MarkdownStylerTests`.
@MainActor
final class PlanTypographyRenderTests: XCTestCase {
    static let section = """
    # Offline sync

    ## Goals

    The first release lets a field engineer keep working with no signal at all. Everything they \
    open while connected stays readable, and anything they change is **queued, never lost**; \
    when the connection returns the queue drains in the order it was written.

    We are deliberately *not* trying to merge two people's edits to the same record. That is a \
    second release, and it needs its own design.

    ## Decisions

    - Local store: one SQLite file per tenant, opened through `OfflineStore`.
    - Queue: every write becomes a row in `outbox`, with the tenant and a monotonic sequence number.
    - Conflicts: the server wins; the client shows the rejected change and offers to re-apply it.

    > Nothing the engineer typed should ever vanish without a visible reason.

    | Area | First-release decision | Acceptance boundary |
    |---|---|---|
    | Reads | Anything opened in the last 14 days is cached for offline use, and nothing older is kept. | A cold start with no network shows cached records. |
    | Writes | Queued locally and replayed in order once the connection is back. | No write is acknowledged twice. |

    ```swift
    func drain() async throws {
        for row in try outbox.pending() { try await send(row) }
    }
    ```

    The drain is idempotent: replaying a row the server already holds is a no-op, so a crash mid-drain only costs a retry.
    """

    static let request = """
    # Dark mode for the settings pane

    Add a **dark** appearance to the settings pane, following the system setting by default. The \
    toggle lives under *General*, and the choice is remembered per window.

    - Keep the existing colours as the light theme.
    - Use `NSAppearance` rather than hand-switching colours.

    It should not flash white on launch.
    """

    private func dir() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FD_PLAN_TYPE_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLAN_TYPE_RENDER_DIR to render the plan typography PNGs")
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return URL(fileURLWithPath: path)
    }

    func testRenderEditor() throws {
        let out = try dir()
        let ns = Self.section as NSString
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (caret, offset) in [("out", ns.length), ("in", ns.range(of: "Queue:").location + 3)] {
                let f = PlanTableEditorTests.editor(Self.section, width: 820, appearance: appearance)
                defer { f.window.close() }
                f.view.setSelectedRange(NSRange(location: offset, length: 0))
                f.settle()
                try PlanTableRenderTests.write(f, width: 820, to: out.appendingPathComponent("editor-\(mode)-caret-\(caret).png"))
            }
        }
    }

    func testRenderComposer() throws {
        let out = try dir()
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try PlanningRender.write(IntakeComposer(intent: .constant(Self.request), onTriage: {}, onCancel: {}, onExpand: {})
                                        .padding(12),
                                     size: NSSize(width: 380, height: 260), to: out.appendingPathComponent("composer-inline-\(mode).png"),
                                     appearance: appearance)
            try PlanningRender.write(ExpandedIntakeComposer(intent: .constant(Self.request), onTriage: {}, onCollapse: {}),
                                     size: NSSize(width: 900, height: 520), to: out.appendingPathComponent("composer-expanded-\(mode).png"),
                                     appearance: appearance)
        }
    }
}
