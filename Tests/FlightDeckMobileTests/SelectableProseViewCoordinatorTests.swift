import UIKit
import XCTest
@testable import FlightDeckMobile

/// Whether `Coordinator.apply` re-assigns `attributedText` only when the prose actually
/// changed, or on every call — which is the difference between a `sizeThatFits` that measures
/// and one that relays out first. A simulator probe (see the commit this ships with) assigned
/// `TimelineProseText.attributed(md)` to a `UITextView` and compared `view.attributedText ==
/// attributed`: false, even though nothing had changed — `UITextView` normalizes what it is
/// handed, so the getter hands back a copy the setter's argument is never `isEqual` to.
/// `assignmentCount` is the seam that makes that regression visible without a timing
/// measurement, which is not something a unit test can assert on.
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

    private func makeView() -> UITextView {
        let view = UITextView()
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
    /// measurement — rather than calling `apply` in isolation.
    func testRepeatedMeasurementWithUnchangedMarkdownAssignsOnce() {
        let coordinator = SelectableProseView.Coordinator(onReply: { _ in })
        let view = makeView()
        let markdown = "A short paragraph of **prose**, unremarkable on purpose."

        for _ in 0..<5 {
            coordinator.apply(markdown, to: view)
            _ = view.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        }

        XCTAssertEqual(
            coordinator.assignmentCount, 1,
            "unchanged markdown measured five times must assign attributedText once, not five"
        )
        XCTAssertEqual(view.attributedText.string, "A short paragraph of prose, unremarkable on purpose.")
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
