import AppKit
import XCTest
@testable import FlightDeck

/// A visual block's view sits over the text view's hidden lines, so VoiceOver and XCUITest reach
/// it (its size and state controls included) only if the text view lists it among its children,
/// as it lists its tables.
@MainActor
final class PlanEditorVisualAccessibilityTests: XCTestCase {
    func testTheTextViewListsItsVisualBlocksAsChildren() {
        let view = PlanNSTextView(usingTextLayoutManager: true)
        let block = VisualBlockView(model: VisualBlockModel(id: "flow", content: .missing), caption: "Flow", store: nil)
        view.addSubview(block)
        XCTAssertTrue((view.accessibilityChildren() ?? []).contains { ($0 as AnyObject) === block })
        let byAttribute = view.accessibilityAttributeValue(.children) as? [Any] ?? []
        XCTAssertTrue(byAttribute.contains { ($0 as AnyObject) === block }, "the server asks by attribute")
    }
}
