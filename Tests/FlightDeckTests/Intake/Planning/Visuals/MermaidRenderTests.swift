import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The vendored Mermaid, drawn offscreen by `VisualRenderHost` (spec §8). A sequence diagram and a
/// flowchart draw; a source that does not parse shows Mermaid's message, in the status the block
/// reads and in the picture (Review Focus 3). Each PNG is written to the render directory when
/// one is set, to be looked at.
@MainActor
final class MermaidRenderTests: XCTestCase {
    private var fixture: VisualFixture!

    override func setUpWithError() throws { fixture = try VisualFixture() }
    override func tearDown() { fixture.remove() }

    private func draw(_ source: String, _ name: String) async throws -> VisualRenderHost.Snapshot {
        try fixture.revision("diagram", r: 1, source: source)
        let host = VisualRenderHost(store: fixture.store)
        let shot = try await host.render(VisualID(rawValue: "diagram")!, r: 1, key: VisualSnapshotKey(state: "default", size: "default"))
        if let dir = VisualFixture.renderDirectory { try shot.png.write(to: dir.appendingPathComponent("mermaid-\(name).png")) }
        return shot
    }

    /// The share of sampled pixels that are not the page's white: a drawn diagram has ink.
    private func ink(_ png: Data) throws -> Double {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        var dark = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if c.redComponent + c.greenComponent + c.blueComponent < 2.7 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    /// Whether the picture has the error box's red in it.
    private func hasErrorRed(_ png: Data) throws -> Bool {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.6, c.greenComponent < 0.3, c.blueComponent < 0.3 { return true }
            }
        }
        return false
    }

    func testASequenceDiagramDraws() async throws {
        let shot = try await draw(VisualFixture.sequence, "sequence")
        guard case .rendered(let width, let height) = shot.status else { return XCTFail("\(shot.status)") }
        XCTAssertGreaterThan(width, 200)
        XCTAssertGreaterThan(height, 150)
        XCTAssertGreaterThan(try ink(shot.png), 0.01, "the picture has the diagram in it, not a blank page")
        XCTAssertFalse(try hasErrorRed(shot.png))
    }

    func testAFlowchartDraws() async throws {
        let shot = try await draw(VisualFixture.flowchart, "flowchart")
        guard case .rendered = shot.status else { return XCTFail("\(shot.status)") }
        XCTAssertGreaterThan(try ink(shot.png), 0.01)
    }

    func testAParseErrorIsShownInTheStatusAndInThePicture() async throws {
        let shot = try await draw(VisualFixture.broken, "parse-error")
        guard case .failed(let message, _) = shot.status else { return XCTFail("drew a broken source: \(shot.status)") }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("parse") || message.localizedCaseInsensitiveContains("expecting"),
                      "Mermaid's own message: \(message)")
        XCTAssertTrue(try hasErrorRed(shot.png), "the picture shows the error box")
    }

    /// V1 review, M5: the empty drawing area kept its padding above the error box, so the message
    /// started about 48 points down. The box now sits at the page's own margin.
    func testTheErrorBoxStartsAtThePagesMarginNotBelowAnEmptyDrawingArea() async throws {
        let shot = try await draw(VisualFixture.broken, "parse-error-top")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: shot.png))
        let scale = CGFloat(rep.pixelsWide) / CGFloat(VisualSize.defaultWidth)
        var firstRed: Int?
        search: for y in 0..<rep.pixelsHigh {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.6, c.greenComponent < 0.3, c.blueComponent < 0.3 { firstRed = y; break search }
            }
        }
        let top = try XCTUnwrap(firstRed)
        XCTAssertLessThanOrEqual(CGFloat(top) / scale, 20, "the box's border is at the 16 pt margin, not 48 pt down")
    }
}
