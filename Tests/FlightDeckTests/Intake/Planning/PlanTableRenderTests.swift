import AppKit
import XCTest
@testable import FlightDeck

/// The plan editor's tables as pictures, for design review: several tables, light and dark, at
/// the editor's usual width and a narrow one, with the caret outside and inside (the grid either way).
/// Skipped unless `FD_PLAN_TABLE_RENDER_DIR` names an output directory. Pictures, not
/// assertions — the layout is asserted in `PlanTable*Tests`.
@MainActor
final class PlanTableRenderTests: XCTestCase {
    static let fixtures: [(name: String, plan: String, inside: Bool)] = [
        ("me", """
        # First-release scope

        What each area decides for the first release, and where the boundary sits.

        | Area | First-release decision | Acceptance boundary |
        |---|---|---|
        | Users | Any eligible employee can create an agent or mini-app; each owner controls a specific invite list for use and can publish their own drafts after automated checks. | Tenant membership alone never grants access to another employee’s app or agent. |
        | Data | Each tenant's records live in that tenant's own store and are never read across tenants. | A query that names no tenant fails closed. |

        ## Rollout

        Ship behind a flag, one tenant at a time.
        """, true),
        ("narrow-two-column", """
        # Flags

        | Flag | Default |
        |---|---|
        | `--dry-run` | off |
        | `--verbose` | off |
        | `--jobs` | 4 |

        Defaults can be overridden per project.
        """, false),
        ("five-columns", """
        # Surfaces

        | Surface | Reads | Writes | When | Owner |
        |---|---|---|---|---|
        | Terminal | `fontSize` | nothing | at surface init | Terminal team |
        | Sidebar preview | `fontSize`, `theme` | nothing | on every redraw of the row | Sidebar team |
        | Settings pane | everything | `fontSize` | when the human edits it | Preferences |
        | Menu bar | none | none | never | none |

        Reads are cheap; writes go through `ProjectSettings`.
        """, false),
        ("inline", """
        # Inline Markdown in cells

        | Name | Notes |
        |---|---|
        | **Bold name** | Uses `code spans`, *italic words* and a [link to the docs](https://example.com/docs). |
        | `ProjectSettings` | Pipes can be escaped: `a \\| b`, and so can the other kind \\| here. |
        | *Plain italic* | **All bold in this cell, which is long enough to wrap onto a second line** |
        """, true),
        ("alignment", """
        # Alignment

        | Left | Centre | Right |
        |:---|:---:|---:|
        | alpha | beta | 1 |
        | a much longer left cell | mid | 1,024 |
        | z | the middle column holds a longer sentence that wraps | 99 |
        """, false),
    ]

    func testRenderTables() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLAN_TABLE_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLAN_TABLE_RENDER_DIR to render the plan table PNGs")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, plan, inside) in Self.fixtures {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for (size, width) in [("wide", CGFloat(820)), ("narrow", 400)] {
                    for caretInside in inside ? [false, true] : [false] {
                        let f = PlanTableEditorTests.editor(plan, width: width, appearance: appearance)
                        defer { f.window.close() }
                        let ns = plan as NSString
                        let table = ns.range(of: "|")
                        f.view.setSelectedRange(NSRange(location: caretInside ? table.location + 4 : ns.range(of: "\n").location, length: 0))
                        f.settle()
                        let file = "\(name)-\(mode)-\(size)-\(caretInside ? "caret" : "grid").png"
                        try Self.write(f, width: width, to: URL(fileURLWithPath: dir).appendingPathComponent(file))
                    }
                }
            }
        }
    }

    /// A selection running down through the grid, and the edit layer over tables: an inserted
    /// row (a bar beside it and its tint) in one, a changed cell (words struck through in it) in another.
    func testRenderSelectionAndEdits() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLAN_TABLE_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLAN_TABLE_RENDER_DIR to render the plan table PNGs")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let plan = Self.fixtures[0].plan
        let ns = plan as NSString
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let selected = PlanTableEditorTests.editor(plan, width: 820, appearance: appearance)
            defer { selected.window.close() }
            selected.view.setSelectedRange(NSRange(location: 20, length: ns.range(of: "A query").location - 20))
            selected.settle()
            try Self.write(selected, width: 820, to: URL(fileURLWithPath: dir).appendingPathComponent("selection-\(mode)-wide-grid.png"))

            let generated = plan.replacingOccurrences(of: "| Data | Each tenant's records live in that tenant's own store and are never read across tenants. | A query that names no tenant fails closed. |\n", with: "")
            let inserted = PlanTableEditorTests.editor(plan, generated: generated, width: 820, appearance: appearance)
            defer { inserted.window.close() }
            inserted.view.setSelectedRange(NSRange(location: 3, length: 0))
            inserted.settle()
            try Self.write(inserted, width: 820, to: URL(fileURLWithPath: dir).appendingPathComponent("edit-inserted-row-\(mode)-wide.png"))

            let changed = plan.replacingOccurrences(of: "fails closed", with: "is refused")
            let edited = PlanTableEditorTests.editor(changed, generated: plan, width: 820, appearance: appearance)
            defer { edited.window.close() }
            edited.view.setSelectedRange(NSRange(location: 3, length: 0))
            edited.settle()
            try Self.write(edited, width: 820, to: URL(fileURLWithPath: dir).appendingPathComponent("edit-changed-cell-\(mode)-wide.png"))
        }
    }

    /// The edit layer's marks inside the grid, one picture each: a changed cell, an inserted row, a
    /// removed row (in the middle, and below the last), an amber wash on a cell, a change across two
    /// cells, and a LarkOS-style table (a narrow Area column, sentence-length cells) with several at once.
    func testRenderMarks() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLAN_TABLE_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLAN_TABLE_RENDER_DIR to render the plan table PNGs")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let small = """
        # Flags

        | Flag | Default | Notes |
        |---|---|---|
        | `--dry-run` | off | Prints what would change. |
        | `--verbose` | off | Logs every step. |
        | `--jobs` | 4 | Parallel workers. |

        Defaults can be overridden per project.
        """
        let larkOS = """
        # First-release scope

        | Area | First-release decision | Acceptance boundary |
        |---|---|---|
        | Users | Any eligible employee can create an agent or mini-app; each owner controls a specific invite list for use. | Tenant membership alone never grants access to another employee's app or agent. |
        | Data | Each tenant's records live in that tenant's own store and are never read across tenants. | A query that names no tenant fails closed. |
        | Billing | Metered per active owner each month, invoiced to the tenant. | Usage is never attributed across tenants. |
        | Legacy | Imported from the old directory in one pass. | The old directory is read-only after import. |
        | Audit | Every grant and revoke is written to the tenant's log. | The log cannot be edited by its tenant's admins. |

        Ship behind a flag, one tenant at a time.
        """
        let states: [(name: String, generated: String, edited: String, amber: String?)] = [
            ("changed-cell", small, small.replacingOccurrences(of: "Prints what would change.", with: "Shows what would change."), nil),
            ("deleted-words", small, small.replacingOccurrences(of: "Logs every step.", with: "Logs steps."), nil),
            ("inserted-row", small, small.replacingOccurrences(of: "| `--jobs` | 4 | Parallel workers. |\n", with: "| `--jobs` | 4 | Parallel workers. |\n| `--quiet` | off | Prints nothing. |\n"), nil),
            ("removed-row", small, small.replacingOccurrences(of: "| `--verbose` | off | Logs every step. |\n", with: ""), nil),
            ("removed-last-row", small, small.replacingOccurrences(of: "| `--jobs` | 4 | Parallel workers. |\n", with: ""), nil),
            ("conflict-in-cell", small, small, "Logs every step."),
            ("inserted-column", small, """
                # Flags

                | Flag | Default | Since | Notes |
                |---|---|---|---|
                | `--dry-run` | off | 1.0 | Prints what would change. |
                | `--verbose` | off | 1.0 | Logs every step. |
                | `--jobs` | 4 | 1.2 | Parallel workers. |

                Defaults can be overridden per project.
                """, nil),
            ("removed-column", small, """
                # Flags

                | Flag | Notes |
                |---|---|
                | `--dry-run` | Prints what would change. |
                | `--verbose` | Logs every step. |
                | `--jobs` | Parallel workers. |

                Defaults can be overridden per project.
                """, nil),
            ("spanning-two-cells", small, small.replacingOccurrences(of: "| `--verbose` | off |", with: "| `--loud` | on |"), nil),
            ("larkos-mixed", larkOS, larkOS
                .replacingOccurrences(of: "Any eligible employee", with: "Any employee")
                .replacingOccurrences(of: " for use.", with: ".")
                .replacingOccurrences(of: "fails closed", with: "is refused")
                .replacingOccurrences(of: "| Billing | Metered per active owner each month, invoiced to the tenant. | Usage is never attributed across tenants. |\n", with: "")
                .replacingOccurrences(of: "| Data |", with: "| Support | Tenant admins file requests; owners approve them. | Requests are answered within one working day. |\n| Data |")
                .replacingOccurrences(of: "| Legacy | Imported from the old directory in one pass. | The old directory is read-only after import. |",
                                      with: "| Archive | Moved from the old directory in one pass. | The old directory is read-only after the move. |"),
             "never read across tenants"),
        ]
        for (name, generated, edited, amber) in states {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let f = PlanTableEditorTests.editor(edited, generated: generated == edited ? nil : generated, width: 820, appearance: appearance)
                defer { f.window.close() }
                if let amber, let layout = f.view.textLayoutManager {
                    let at = (edited as NSString).range(of: amber)
                    f.coordinator.churnTint.apply([(at, [.backgroundColor: PlanTextView.Coordinator.churnColor])], to: layout)
                }
                f.view.setSelectedRange(NSRange(location: 3, length: 0))
                f.settle()
                try Self.write(f, width: 820, to: URL(fileURLWithPath: dir).appendingPathComponent("marks-\(name)-\(mode).png"))
            }
        }
    }

    static func write(_ f: PlanTableEditorTests.Fixture, width: CGFloat, to url: URL) throws {
        let height = ceil(f.container.contentHeight) + 8
        f.window.setContentSize(NSSize(width: width, height: height))
        f.container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        f.window.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        f.container.layoutSubtreeIfNeeded()
        f.settle()
        f.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        f.container.layoutSubtreeIfNeeded()
        f.view.displayIfNeeded()
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.scaleBy(x: scale, y: scale)
        try XCTUnwrap(f.window.contentView?.layer).render(in: context)
        f.window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
