import MarkdownUI
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Draws the plan reader's tables at phone width so they can be looked at.
///
/// **Not a test, and it asserts nothing**, as `ProseRenderHarness`: how a table wraps and where
/// its lines sit is a picture. Skipped unless `RENDER_PLAN_TABLE` is an absolute output directory
/// (set in the scheme for one run, or by an empty `.render` file in
/// `DerivedData/plan-table-renders-ios`, which an app-hosted suite can see as the simulator
/// shares this Mac's file system).
@MainActor
final class PlanTableRenderHarness: XCTestCase {
    static let samples: [(name: String, markdown: String)] = [
        ("me", """
        | Area | First-release decision | Acceptance boundary |
        |---|---|---|
        | Users | Any eligible employee can create an agent or mini-app; each owner controls a specific invite list for use and can publish their own drafts after automated checks. | Tenant membership alone never grants access to another employee’s app or agent. |
        | Data | Each tenant's records live in that tenant's own store and are never read across tenants. | A query that names no tenant fails closed. |
        """),
        ("me-mixed", """
        | Area | First-release decision | Acceptance boundary |
        |---|---|---|
        | Users | Any eligible employee can create an agent or mini-app; each owner controls a specific invite list for use and can publish their own drafts after automated checks. | Tenant membership alone never grants access to another employee’s app or agent. |
        | Data | **Each** tenant's `records` stay in its own store. | A query that names no tenant fails closed. |
        """),
        ("two-column", """
        | Flag | Default |
        |---|---|
        | `--dry-run` | off |
        | `--verbose` | off |
        | `--jobs` | 4 |
        """),
        ("five-columns", """
        | Surface | Reads | Writes | When | Owner |
        |---|---|---|---|---|
        | Terminal | `fontSize` | nothing | at surface init | Terminal team |
        | Sidebar preview | `fontSize`, `theme` | nothing | on every redraw of the row | Sidebar team |
        | Settings pane | everything | `fontSize` | when the human edits it | Preferences |
        """),
        ("inline-alignment", """
        | Name | Centre | Right |
        |:---|:---:|---:|
        | **Bold name** | *italic* and `code` | [link](https://example.com) |
        | `ProjectSettings` | a \\| b | 1,024 |
        """),
    ]

    private var directory: URL? {
        if let value = ProcessInfo.processInfo.environment["RENDER_PLAN_TABLE"], value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let marked = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/plan-table-renders-ios", isDirectory: true)
        return FileManager.default.fileExists(atPath: marked.appendingPathComponent(".render").path) ? marked : nil
    }

    func testDrawTables() throws {
        try XCTSkipUnless(self.directory != nil, "set RENDER_PLAN_TABLE to draw the plan tables")
        let directory = self.directory!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, markdown) in Self.samples {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for width in [CGFloat(346), 320] {
                    let image = image(of: reader(markdown), style: style, width: width)
                    let file = "\(name)-\(style == .light ? "light" : "dark")-\(Int(width)).png"
                    try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(file))
                    if name == "me-mixed", width == 346 {
                        let old = self.image(of: before(markdown), style: style, width: width)
                        try XCTUnwrap(old.pngData()).write(to: directory.appendingPathComponent("before-\(file)"))
                    }
                    print("RENDERED \(file) \(Int(image.size.width))x\(Int(image.size.height))")
                }
            }
        }
    }

    /// What the reader draws for a table block (`PlanReaderScreen.segmentView`).
    private func reader(_ markdown: String) -> some View {
        RichBlockView(text: markdown).font(.body)
            .padding(12)
    }

    /// What MarkdownUI drew, for the comparison.
    private func before(_ markdown: String) -> some View {
        Markdown(markdown).markdownTheme(TimelineMarkdown.theme).font(.body).padding(12)
    }

    private func measure(_ view: some View, width: CGFloat) -> CGFloat {
        let controller = UIHostingController(rootView: view)
        controller.safeAreaRegions = []
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 4000)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// Measured in one window, drawn in another (`ProseRenderHarness.image`).
    private func image(of view: some View, style: UIUserInterfaceStyle, width: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: measure(view.frame(width: width), width: width) + 8)
        let controller = UIHostingController(rootView: view.frame(width: width))
        controller.safeAreaRegions = []
        controller.overrideUserInterfaceStyle = style
        controller.view.backgroundColor = .systemBackground
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = style
        window.isHidden = false
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
}
