import XCTest
import IntakeKit

/// The pure rules under the Mac's visual blocks (planning v2 §8, V-R2): the `fdvisual:` URL a web
/// view may load, which snapshots a revision gets, the named sizes, and the budget of live web views.
final class VisualRenderingTests: XCTestCase {
    private let id = VisualID(rawValue: "pairing-handshake")!

    // MARK: - fdvisual URLs

    func testAFileURLRoundTrips() throws {
        let url = VisualScheme.url(.file(id, r: 3, path: "src/diagram.mmd"))
        XCTAssertEqual(url.absoluteString, "fdvisual://pairing-handshake/r3/src/diagram.mmd")
        XCTAssertEqual(VisualScheme.parse(url), .file(id, r: 3, path: "src/diagram.mmd"))
    }

    func testThePageURLCarriesItsStateAndSize() throws {
        let url = VisualScheme.url(.page(id, r: 1, state: "dark", size: "phone"))
        XCTAssertEqual(VisualScheme.parse(url), .page(id, r: 1, state: "dark", size: "phone"))
        XCTAssertEqual(VisualScheme.parse(URL(string: "fdvisual://pairing-handshake/r1/")!), .page(id, r: 1, state: nil, size: nil))
    }

    func testTheLibraryURLIsNotARevisionPath() {
        let url = VisualScheme.url(.library(id, name: "mermaid.min.js"))
        XCTAssertEqual(url.absoluteString, "fdvisual://pairing-handshake/lib/mermaid.min.js")
        XCTAssertEqual(VisualScheme.parse(url), .library(id, name: "mermaid.min.js"))
    }

    func testANameWithSpacesIsEncodedAndDecoded() {
        let url = VisualScheme.url(.file(id, r: 1, path: "snapshot@a b-default.png"))
        XCTAssertEqual(VisualScheme.parse(url), .file(id, r: 1, path: "snapshot@a b-default.png"))
    }

    func testAnythingElseIsNotAVisualURL() {
        for raw in ["http://pairing-handshake/r1/diagram.mmd",          // another scheme
                    "fdvisual://Pairing/r1/diagram.mmd",                 // not a usable id
                    "fdvisual://pairing-handshake/r01/diagram.mmd",      // a second name for r1
                    "fdvisual://pairing-handshake/r-1/diagram.mmd",
                    "fdvisual://pairing-handshake/x1/diagram.mmd",
                    "fdvisual://pairing-handshake/r1",                    // no trailing slash
                    "fdvisual://pairing-handshake/",
                    "fdvisual://pairing-handshake/r1/a%2Fb",              // an encoded slash is not a separator
                    "fdvisual://pairing-handshake/r1/a%00b",
                    "fdvisual://pairing-handshake/r1/diagram.mmd?x=1",   // a file takes no query
                    "fdvisual://user@pairing-handshake/r1/diagram.mmd",
                    "fdvisual://pairing-handshake:80/r1/diagram.mmd",
                    "fdvisual://pairing-handshake/lib/",
                    "fdvisual://pairing-handshake/lib/a/b.js"] {
            XCTAssertNil(VisualScheme.parse(URL(string: raw)!), raw)
        }
    }

    func testDotSegmentsPassThroughToTheStoreWhichRefusesThem() {
        // Not normalised here: `..` reaches `read`, whose confinement refuses it, so there is one
        // place that decides and the URL layer cannot hide a traversal by resolving it first.
        XCTAssertEqual(VisualScheme.parse(URL(string: "fdvisual://pairing-handshake/r1/a/../../b")!),
                       .file(id, r: 1, path: "a/../../b"))
    }

    // MARK: - Snapshot set (spec §8)

    func testEveryStateAtTheDefaultSizePlusTheDefaultStateAtEverySize() {
        let keys = VisualSnapshotPlan.keys(states: ["idle", "pairing", "failed"], sizes: ["mac", "phone"])
        XCTAssertEqual(keys.map(\.fileName), ["snapshot@idle-mac.png", "snapshot@pairing-mac.png",
                                              "snapshot@failed-mac.png", "snapshot@idle-phone.png"])
    }

    func testNoStatesOrSizesIsOneDefaultSnapshot() {
        XCTAssertEqual(VisualSnapshotPlan.keys(states: [], sizes: []).map(\.fileName), ["snapshot@default-default.png"])
        XCTAssertEqual(VisualSnapshotPlan.keys(states: ["a"], sizes: []).map(\.fileName), ["snapshot@a-default.png"])
    }

    func testANameThatIsNotSafeInAFileNameIsLeftOut() {
        let keys = VisualSnapshotPlan.keys(states: ["ok", "../up", "a/b", ".hidden", ""], sizes: ["mac"])
        XCTAssertEqual(keys.map(\.fileName), ["snapshot@ok-mac.png"])
    }

    func testRepeatedNamesAreSnapshottedOnce() {
        XCTAssertEqual(VisualSnapshotPlan.keys(states: ["a", "a"], sizes: ["m", "m"]).count, 1)
    }

    // MARK: - Named sizes

    func testNamedSizesHaveWidths() {
        XCTAssertEqual(VisualSize.width("default"), 760)
        XCTAssertEqual(VisualSize.width("phone"), 390)
        XCTAssertEqual(VisualSize.width("tablet"), 768)
        XCTAssertEqual(VisualSize.width("mac"), 1024)
        XCTAssertEqual(VisualSize.width("640"), 640)
        XCTAssertEqual(VisualSize.width("1280x800"), 1280)
        XCTAssertEqual(VisualSize.width("nonsense"), 760, "an unknown name draws at the default width")
        XCTAssertEqual(VisualSize.width("99999"), 2400, "clamped, so a manifest cannot ask for a giant bitmap")
        XCTAssertEqual(VisualSize.width("10"), 200)
    }

    // MARK: - Live web views

    func testAtMostThreeAreLiveAndTheLeastRecentlyUsedGoesBack() {
        var budget = VisualLiveBudget<String>(limit: 3)
        XCTAssertNil(budget.use("a"))
        XCTAssertNil(budget.use("b"))
        XCTAssertNil(budget.use("c"))
        XCTAssertNil(budget.use("a"), "already live: used again, nothing goes back")
        XCTAssertEqual(budget.use("d"), "b", "b is now the least recently used")
        XCTAssertEqual(budget.live, ["c", "a", "d"])
        XCTAssertEqual(budget.live.count, 3)
    }

    func testReleasingFreesASlot() {
        var budget = VisualLiveBudget<String>(limit: 3)
        _ = budget.use("a"); _ = budget.use("b"); _ = budget.use("c")
        budget.release("b")
        XCTAssertFalse(budget.isLive("b"))
        XCTAssertNil(budget.use("d"))
        XCTAssertTrue(budget.hasRoom == false)
    }
}
