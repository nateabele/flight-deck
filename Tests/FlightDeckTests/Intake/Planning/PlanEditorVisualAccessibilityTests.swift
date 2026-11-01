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
        XCTAssertEqual((view.accessibilityChildren() ?? []).filter { ($0 as AnyObject) === block }.count, 1)
        let byAttribute = view.accessibilityAttributeValue(.children) as? [Any] ?? []
        XCTAssertEqual(byAttribute.filter { ($0 as AnyObject) === block }.count, 1,
                       "the server asks by attribute, and lists each block once")
    }
}
