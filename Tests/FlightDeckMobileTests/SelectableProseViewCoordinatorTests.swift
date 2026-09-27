import UIKit
import XCTest
@testable import FlightDeckMobile

/// Whether `Coordinator.apply` re-assigns `attributedText` only when the prose actually
/// changed, or on every call — which is the difference between a `sizeThatFits` that measures
/// and one that relays out first. A simulator probe (see the commit this ships with) assigned
/// `TimelineProseText.attributed(md)` to a `UITextView` and compared `view.attributedText ==
/// attributed`: for link/code-bearing prose — the shape of the 3.7K-character message the
/// regression was measured against — that came back false; simple prose can round-trip equal.
/// That is exactly why comparing against the getter is unreliable rather than merely slow, and
/// why `testRepeatedMeasurementWithUnchangedMarkdownAssignsOnce` below uses link/code-bearing
/// markdown rather than something simpler. `assignmentCount` is the seam that makes the
/// regression visible without a timing measurement, which is not something a unit test can
/// assert on.
@MainActor
final class SelectableProseViewCoordinatorTests: XCTestCase {

    /// **Windowed, not bare.** `traitOverrides` (used by the content-size-category test below)
    /// only reaches `traitCollection` once the system has run a resolution pass, which a view
    /// with no window never gets — so every test mounts through a key window, the same
    /// requirement `ProseExpansionRecyclingTests`' harness documents for SwiftUI layout.
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// Configured like `SelectableProseView.makeUIView` (and the probe that measured the
    /// regression) rather than a bare `UITextView` — `isScrollEnabled`/`textContainerInset`/
    /// `lineFragmentPadding` all affect layout, and the getter round-trip this file exists to
    /// route around is content- and configuration-dependent, so a fixture that doesn't match
    /// production risks a test that passes for the wrong reason.
    private func makeView() -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 800))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window
        return view
    }

    /// **The regression this whole file exists to catch.** `SelectableProseView.sizeThatFits`
    /// calls `apply` and then measures on every pass, and a scrolling list measures the same row
    /// repeatedly, so this drives that exact sequence — apply, then the real `UITextView`
    /// measurement — rather than calling `apply` in isolation. The markdown is link/code-bearing
    /// on purpose: that is the shape the getter round-trip actually goes unequal for (see the
    /// file-level comment above), so simple prose here would pass even against the old
    /// `view.attributedText != attributed` guard and not pin the regression at all.
    func testRepeatedMeasurementWithUnchangedMarkdownAssignsOnce() {
        let coordinator = SelectableProseView.Coordinator(onReply: { _ in })
        let view = makeView()
        let para = "This is **bold** prose with `code`, a [link](https://example.com) and some " +
            "_emphasis_ that wraps across several lines on a phone. "
        let markdown = (0..<12)
            .map { i in "Paragraph \(i). " + String(repeating: para, count: 3) }
            .joined(separator: "\n\n")

        for _ in 0..<5 {
            coordinator.apply(markdown, to: view)
            _ = view.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        }

        XCTAssertEqual(
            coordinator.assignmentCount, 1,
            "unchanged link/code-bearing markdown measured five times must assign attributedText once, not five"
        )
        XCTAssertTrue(view.attributedText.string.hasPrefix("Paragraph 0."))
    }

    /// The first call is the one `sizeThatFits`'s own comment calls "not belt-and-braces": a
    /// view that has never had anything assigned must get it on the very first `apply`, before
    /// anything is measured.
    func testFirstApplyAssignsImmediately() {
        let coordinator = SelectableProseView.Coordinator(onReply: { _ in })
        let view = makeView()

        coordinator.apply("first render", to: view)

        XCTAssertEqual(coordinator.assignmentCount, 1)
        XCTAssertEqual(view.attributedText.string, "first render")
    }

    /// New markdown is new prose on screen, guard or no guard.
    func testChangedMarkdownReassigns() {
        let coordinator = SelectableProseView.Coordinator(onReply: { _ in })
        let view = makeView()

        coordinator.apply("before", to: view)
        coordinator.apply("before", to: view)
        coordinator.apply("after", to: view)

        XCTAssertEqual(
            coordinator.assignmentCount, 2,
            "the second distinct markdown must be assigned even though the first repeated"
        )
        XCTAssertEqual(view.attributedText.string, "after")
    }

    /// A larger Dynamic Type category invalidates the parse cache (`cachedCategory`'s own
    /// comment) even though the markdown string is byte-identical, so it must reassign —
    /// exactly the case a guard keyed on the attributed string's *content* would miss.
    func testChangedContentSizeCategoryReassigns() {
        let coordinator = SelectableProseView.Coordinator(onReply: { _ in })
        let view = makeView()

        coordinator.apply("same text", to: view)
        view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window?.layoutIfNeeded()
        coordinator.apply("same text", to: view)

        XCTAssertEqual(
            coordinator.assignmentCount, 2,
            "a content-size-category change must reassign even though the markdown is identical"
        )
    }
}
