import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

@MainActor
final class TimelineSkeletonRowTests: XCTestCase {
    func testAPlaceholderRowRendersItsPreviewRatherThanBlank() {
        var body = TimelineItem.Body(text: "the first line of a spilled body")
        body.isPlaceholder = true
        let item = TimelineItem(id: "0#0", kind: .assistantText, status: .complete, body: body)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        window.rootViewController = UIHostingController(rootView:
            TimelineSkeletonRow(item: item).frame(width: 402))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        window.layoutIfNeeded()

        let size = window.rootViewController!.view.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height))
        XCTAssertGreaterThan(size.height, 10, "a skeleton row draws its preview, not nothing")
        window.isHidden = true
    }
}
