import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Draws the plan reader's type at phone width so it can be looked at: a realistic section
/// (heading, paragraphs, a list, a quote, a table, a code block), light and dark.
///
/// **Not a test, and it asserts nothing** — see `PlanTableRenderHarness`. Skipped unless
/// `RENDER_PLAN_TYPE` is an absolute output directory, or an empty `.render` file sits in
/// `DerivedData/plan-type-renders-ios`.
@MainActor
final class PlanTypographyRenderHarness: XCTestCase {
    static let section = """
    # Offline sync

    ## Goals

    The first release lets a field engineer keep working with no signal at all. Everything they open while connected stays readable, and anything they change is **queued, never lost**; when the connection returns the queue drains in the order it was written.

    We are deliberately *not* trying to merge two people's edits to the same record. That is a second release, and it needs its own design.

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

    private var directory: URL? {
        if let value = ProcessInfo.processInfo.environment["RENDER_PLAN_TYPE"], value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let marked = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/plan-type-renders-ios", isDirectory: true)
        return FileManager.default.fileExists(atPath: marked.appendingPathComponent(".render").path) ? marked : nil
    }

    func testDrawPlan() throws {
        try XCTSkipUnless(directory != nil, "set RENDER_PLAN_TYPE to draw the plan reader")
        let directory = self.directory!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = image(of: reader(Self.section), style: style, width: 393)
            let file = "reader-\(style == .light ? "light" : "dark").png"
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(file))
            print("RENDERED \(file) \(Int(image.size.width))x\(Int(image.size.height))")
        }
    }

    /// The reader's column: each block's segments as `PlanReaderScreen` stacks them.
    private func reader(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: PlanReaderStyle.blockSpacing) {
            ForEach(PlanBlocks.split(markdown).blocks, id: \.index) { block in
                VStack(alignment: .leading, spacing: PlanReaderStyle.segmentSpacing) {
                    ForEach(Array(PlanReaderStyle.segments(of: block.text).enumerated()), id: \.offset) { _, segment in
                        PlanSegmentView(segment: segment)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
            }
        }
        .padding(16)
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
