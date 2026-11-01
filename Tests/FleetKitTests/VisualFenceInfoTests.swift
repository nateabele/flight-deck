import XCTest
import FleetKit

/// The one parser for `fd-visual` fence info strings (R-I4). IntakeKit keeps a copy that cannot
/// import this one; `VisualFenceInfoCrossCheckTests` pins the two together.
final class VisualFenceInfoTests: XCTestCase {
    func testParsesIdAndPendingInAnyOrder() {
        XCTAssertEqual(VisualFenceInfo.parse("fd-visual id=a")?.id, "a")
        XCTAssertEqual(VisualFenceInfo.parse("fd-visual id=a")?.pending, false)
        XCTAssertEqual(VisualFenceInfo.parse("fd-visual id=a pending")?.pending, true)
        XCTAssertEqual(VisualFenceInfo.parse("fd-visual pending id=a")?.id, "a")
        XCTAssertEqual(VisualFenceInfo.parse("fd-visual\tid=a")?.id, "a")
    }

    func testAnythingElseIsNotAVisual() {
        for info in ["", "swift", "fd-visual", "fd-visual id=", "fd-visual id=../x", "fd-visual id=Foo", "fd-visualx id=a",
                     "fd-visual-2 id=a", "FD-VISUAL id=a", "xfd-visual id=a"] {
            XCTAssertNil(VisualFenceInfo.parse(info), info)
        }
    }

    func testTheIdRuleIsLowercaseAsciiAndFolderSafe() {
        for good in ["a", "0", "pairing-handshake", "v1.2_x", String(repeating: "a", count: 64)] { XCTAssertTrue(VisualFenceInfo.isValidID(good), good) }
        for bad in ["", "A", "-a", "_a", ".a", "a/b", "a b", "é", String(repeating: "a", count: 65)] { XCTAssertFalse(VisualFenceInfo.isValidID(bad), bad) }
    }
}
