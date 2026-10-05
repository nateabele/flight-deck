import XCTest
import SwiftUI
import AppKit
@testable import FlightDeck

/// The Meter Gallery UI test reads `.value` off the `meter-bar` element. A VStack with ignored
/// children surfaced as an AXGroup and XCUITest reported "" for it, so every bar had a name and
/// no reading. This walks the NSAccessibility tree in-process so the role and value are pinned
/// without a GUI run.
///
/// SwiftUI builds that tree only for a connected accessibility client. This runner is not
/// AX-trusted (AXIsProcessTrusted is false), so the hosting view reports a bare AXGroup with no
/// children and the tree tests skip with that reason. They assert for real whenever the tree is
/// reachable, and the UI test stays the authority on the live run.
@MainActor
final class MeterAccessibilityTests: XCTestCase {
    private let model = AccountMeterModel(id: "a", label: "Work", fraction: 0.82, state: .overSoft, soft: 0.8, hard: 0.95,
                                          resetText: "resets 11:00 PM", sourceText: "claude mod · 3 min ago", detail: nil)

    private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        let hv = NSHostingView(rootView: view)
        hv.frame = NSRect(x: 0, y: 0, width: 320, height: 90)
        let w = NSWindow(contentRect: hv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        w.orderFront(nil)
        hv.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (w, hv)
    }

    private func walk(_ e: Any, depth: Int = 0, into out: inout [NSAccessibilityProtocol]) {
        guard depth < 12, let el = e as? NSAccessibilityProtocol else { return }
        out.append(el)
        for c in el.accessibilityChildren() ?? [] { walk(c, depth: depth + 1, into: &out) }
    }

    private func nodes<V: View>(_ view: V, id: String) throws -> (window: NSWindow, matches: [NSAccessibilityProtocol], dump: String) {
        let (w, hv) = host(view)
        var all: [NSAccessibilityProtocol] = []
        walk(hv, into: &all)
        try XCTSkipIf(all.count <= 1, "SwiftUI exposes no accessibility tree to an AX-untrusted process; the UI test covers it")
        let dump = all.map { "role=\($0.accessibilityRole()?.rawValue ?? "nil") id=\($0.accessibilityIdentifier() ?? "") label=\($0.accessibilityLabel() ?? "nil") value=\(String(describing: $0.accessibilityValue()))" }.joined(separator: "\n")
        return (w, all.filter { ($0.accessibilityIdentifier() ?? "") == id }, dump)
    }

    func testMeterBarExposesLabelAndValue() throws {
        let r = try nodes(AccountMeterBar(model: model), id: "meter-bar")
        let bar = try XCTUnwrap(r.matches.first, r.dump)
        XCTAssertEqual(r.matches.count, 1, r.dump)
        XCTAssertEqual(bar.accessibilityLabel(), model.label)
        XCTAssertEqual(bar.accessibilityValue() as? String, model.accessibilityValue)
        XCTAssertNotEqual(bar.accessibilityRole(), .group, "XCUITest reports no value for a group")
    }

    func testRowMiniMeterIsOneElement() throws {
        let r = try nodes(RowMiniMeter(model: model), id: "row-mini-meter")
        XCTAssertEqual(r.matches.count, 1, r.dump)
    }

    /// The part reachable without a tree: the reading the bar must carry is non-empty and
    /// names the state, so a Text-backed element has something to expose.
    func testTheReadingTheBarCarriesIsNotEmpty() {
        XCTAssertTrue(model.accessibilityValue.contains("82 percent used, past its soft limit"))
    }
}
