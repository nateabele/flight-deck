import MarkdownUI
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Draws the same prose through both renderers so they can be looked at together.
///
/// **Not a test, and it asserts nothing.** Whether an attributed heading sits at the same
/// weight as a MarkdownUI one, whether a code span's wash lines up, whether a paragraph gap is
/// `.em(0.7)` in both — none of that is reachable by an assertion, and a test that claimed to
/// check it would be re-reading the source. What this does is put the two side by side and
/// write a PNG, which is the only way the question gets an answer.
///
/// Skipped unless `RENDER_PROSE` is set, because it needs a window and costs a second per
/// image. Run it with:
///
///     xcodebuild test -project FlightDeck.xcodeproj -scheme FlightDeckMobile \
///       -destination 'id=<a booted simulator>' \
///       -only-testing:FlightDeckMobileTests/ProseRenderHarness \
///       TEST_RUNNER_RENDER_PROSE=1
@MainActor
final class ProseRenderHarness: XCTestCase {

    private static let sample = """
    ## What the migration does

    It drains the queue **before** flipping the flag, because a job that starts under the old
    flag and finishes under the new one writes a row neither side can read. Call `drain()`
    first and check `queue.isEmpty` — *not* `queue.count == 0`, which races.

    See the [runbook](https://example.com/runbook) for the rollback.
    """

    func testDrawBothRenderers() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RENDER_PROSE"] != nil,
            "set RENDER_PROSE to draw the comparison"
        )
        let markdownOnly = Markdown(Self.sample)
            .markdownTheme(TimelineMarkdown.theme)
            .font(.body)
            .frame(width: 346, alignment: .leading)
        let attributedOnly = SelectableProseView(markdown: Self.sample, onReply: { _ in })
            .font(.body)
            .frame(width: 346, alignment: .leading)
        print("HEIGHT markdown=\(measure(markdownOnly)) attributed=\(measure(attributedOnly))")

        for style in [UIUserInterfaceStyle.light, .dark] {
            let name = style == .light ? "light" : "dark"
            try write(image(of: comparison, style: style), to: "prose-renderers-\(name).png")
        }
    }

    /// The two, stacked, each under its own label. Stacked rather than side by side because the
    /// column width is the variable that matters — prose at 370pt wraps where the row wraps,
    /// and two 185pt columns would compare something neither renderer ever draws.
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 16) {
            label("MarkdownUI — the theme")
            Markdown(Self.sample)
                .markdownTheme(TimelineMarkdown.theme)
                .font(.body)
            Divider()
            label("SelectableProseView — the same theme, as attributes")
            SelectableProseView(markdown: Self.sample, onReply: { _ in })
                .font(.body)
        }
        .padding(12)
        .frame(width: 370, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func measure(_ view: some View) -> CGFloat {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 370, height: 4000)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        return controller.sizeThatFits(in: CGSize(width: 370, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// **Measured in one window, drawn in another**, which is not tidiness: a controller sized
    /// before its hierarchy has laid out under-reports a `UIViewRepresentable` by a line, and a
    /// controller whose window is resized after layout draws nothing at all. Each half of this
    /// wants the opposite order, so each gets its own pass.
    private func image(of view: some View, style: UIUserInterfaceStyle) -> UIImage {
        let height = measure(view.frame(width: 370)) + 24
        let size = CGSize(width: 370, height: height)

        let controller = UIHostingController(rootView: view)
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

    private func write(_ image: UIImage, to name: String) throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        print("RENDERED \(url.path) \(Int(image.size.width))×\(Int(image.size.height))")
    }
}
