import XCTest
import IntakeKit
@testable import FlightDeck

/// Four branches assert against these fixtures, so their meaning is pinned once, here.
final class L3FixtureTests: XCTestCase {
    func testBrRowsDecodeAsDocumented() throws {
        let rows = try L3Fixtures.brRows()
        func decode(_ id: String) -> Result<ExecutionBlock?, ExecutionBlockError> {
            ExecutionBlockCodec.decode(agentContext: rows.first { $0["id"] as? String == id }?["agent_context"] as? String)
        }
        XCTAssertEqual(try decode("fx-valid").get()?.kind, "snapshot-tests")
        XCTAssertEqual(try decode("fx-pinned").get()?.pinned, true)
        XCTAssertEqual(decode("fx-invalid"), .failure(.missingField("model")))
        XCTAssertNil(try decode("fx-none").get())
        XCTAssertEqual(decode("fx-newer"), .failure(.unsupportedVersion(2)))
    }

    func testKindsFixtureResolvesMerged() throws {
        let file = try L3Fixtures.kinds()
        XCTAssertEqual(KindResolution.resolve("golden-tests", in: file.kinds)?.id, "snapshot-tests")
        for k in file.kinds { XCTAssertNoThrow(try k.validate()) }
    }

    func testUsageTimelineCrossesSoftThenHard() throws {
        let t = try L3Fixtures.usageTimeline()
        XCTAssertEqual(t.map { $0.worstWindow?.utilization }, [0.50, 0.82, 0.96, nil, 0.34])
        XCTAssertEqual(t.map(\.hardRejection), [false, false, false, true, false])
    }
}
