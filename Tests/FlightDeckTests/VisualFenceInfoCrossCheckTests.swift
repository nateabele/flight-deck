import XCTest
import FleetKit
import IntakeKit

/// `VisualFenceInfo` (FleetKit, used by MarkdownStyler) and `PlanVisualFence` (IntakeKit, used by
/// PlanExporter) cannot share code, because IntakeKit does not import FleetKit. They must still
/// agree on every info string, or the editor and the export would disagree about which blocks
/// are visuals. This test sees both modules and pins them to the same cases.
final class VisualFenceInfoCrossCheckTests: XCTestCase {
    private static let cases: [(info: String, expected: (id: String, pending: Bool)?)] = [
        ("fd-visual id=a", ("a", false)),
        ("fd-visual id=a pending", ("a", true)),
        ("fd-visual pending id=a", ("a", true)),
        ("fd-visual   id=pairing-handshake  ", ("pairing-handshake", false)),
        ("fd-visual\tid=v1.2_x\tpending", ("v1.2_x", true)),
        ("fd-visual id=a id=b", ("b", false)),
        ("fd-visual id=a extra", ("a", false)),
        ("", nil), ("swift", nil), ("fd-visual", nil), ("fd-visual id=", nil), ("fd-visual id=../x", nil),
        ("fd-visual id=Foo", nil), ("fd-visual id=-a", nil), ("fd-visual id=a/b", nil), ("fd-visualx id=a", nil),
        ("fd-visual-2 id=a", nil), ("FD-VISUAL id=a", nil), ("pending id=a", nil),
        ("fd-visual id=" + String(repeating: "a", count: 65), nil),
        ("fd-visual id=é", nil),
    ]

    func testBothCopiesAgreeOnEveryCase() {
        for (info, expected) in Self.cases {
            let fleet = VisualFenceInfo.parse(info), intake = PlanVisualFence.parse(info)
            XCTAssertEqual(fleet?.id, expected?.id, "FleetKit: \(info)")
            XCTAssertEqual(fleet?.pending, expected?.pending, "FleetKit: \(info)")
            XCTAssertEqual(intake?.id, expected?.id, "IntakeKit: \(info)")
            XCTAssertEqual(intake?.pending, expected?.pending, "IntakeKit: \(info)")
        }
    }

    func testBothCopiesAgreeOnTheIdRule() {
        for id in ["a", "A", "0", "-", ".", "a.b", "a_b", "a b", "é", "", String(repeating: "a", count: 64), String(repeating: "a", count: 65)] {
            XCTAssertEqual(VisualFenceInfo.isValidID(id), VisualID.isValid(id), id)
        }
    }

    /// IntakeKit's per-file cap is a copy of the wire's whole-revision cap.
    func testTheStoreCapMatchesTheWireCap() {
        XCTAssertEqual(VisualStoreLimits.maxFileBytes, VisualLimits.maxBytes)
    }

    /// The phone's size widths (FleetKit) and the Mac's (IntakeKit, what snapshots are drawn at).
    func testBothCopiesAgreeOnTheWidthOfEverySizeName() {
        for name in ["default", "phone", "compact", "tablet", "mac", "desktop", "wide", "Phone", "WIDE", "narrow", "", "640", "500x900",
                     "5", "99999", "0", "x", "12x", "abc", "1e3", "-5"] {
            XCTAssertEqual(VisualSizeWidth.width(name), VisualSize.width(name), name)
        }
        XCTAssertEqual(VisualSizeWidth.defaultWidth, VisualSize.defaultWidth)
        XCTAssertEqual(VisualSizeWidth.range, VisualSize.range)
    }
}
