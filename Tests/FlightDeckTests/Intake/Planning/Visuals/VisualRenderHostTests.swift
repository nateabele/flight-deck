import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// `VisualRenderHost.writeSnapshots` writes exactly the spec §8 set, named
/// `snapshot@<state>-<size>.png`, into the folder it is handed: here a test revision folder,
/// because the real `visuals/` writer is ThreadRunner (P2a-integration).
@MainActor
final class VisualRenderHostTests: XCTestCase {
    private var fixture: VisualFixture!

    override func setUpWithError() throws { fixture = try VisualFixture() }
    override func tearDown() { fixture.remove() }

    func testTheSnapshotSetFollowsTheSpecRule() async throws {
        let dir = try fixture.revision("states", r: 1, source: VisualFixture.flowchart,
                                       states: ["idle", "failed"], sizes: ["default", "phone"])
        let host = VisualRenderHost(store: fixture.store)
        let shots = try await host.writeSnapshots(VisualID(rawValue: "states")!, r: 1, to: dir)
        let expected = ["snapshot@idle-default.png", "snapshot@failed-default.png", "snapshot@idle-phone.png"]
        XCTAssertEqual(shots.map(\.key.fileName), expected)
        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("snapshot@") }.sorted()
        XCTAssertEqual(written, expected.sorted())
        for name in expected {
            let png = try Data(contentsOf: dir.appendingPathComponent(name))
            XCTAssertNotNil(NSBitmapImageRep(data: png), name)
        }
        // The phone size is narrower: its picture is drawn at 390 points, not 760.
        let phone = try XCTUnwrap(shots.last)
        let wide = try XCTUnwrap(shots.first)
        XCTAssertLessThan(phone.pixelSize.width, wide.pixelSize.width)
        if let render = VisualFixture.renderDirectory {
            for name in expected { try? FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: render.appendingPathComponent("host-\(name)")) }
        }
    }

    func testARevisionThatIsNotThereIsAnError() async throws {
        let host = VisualRenderHost(store: fixture.store)
        do {
            _ = try await host.writeSnapshots(VisualID(rawValue: "nothing")!, r: 1, to: fixture.root.appendingPathComponent("out"))
            XCTFail("wrote snapshots of nothing")
        } catch let error as VisualRenderHost.Failure {
            XCTAssertEqual(error, .noRevision)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("out").path), "nothing written")
    }

    func testDrawsWaitTheirTurn() async throws {
        try fixture.revision("a", r: 1, source: VisualFixture.flowchart)
        try fixture.revision("b", r: 1, source: VisualFixture.sequence)
        let host = VisualRenderHost(store: fixture.store)
        let key = VisualSnapshotKey(state: "default", size: "default")
        async let a = host.render(VisualID(rawValue: "a")!, r: 1, key: key)
        async let b = host.render(VisualID(rawValue: "b")!, r: 1, key: key)
        let (sa, sb) = try await (a, b)
        guard case .rendered = sa.status, case .rendered = sb.status else { return XCTFail("\(sa.status) \(sb.status)") }
    }
}
