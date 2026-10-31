import XCTest
import FleetKit

/// Visual blocks on the fleet wire (P2a V0): the projection's references, the capability flag
/// and the fetch op, as bytes. Pure FleetKit, nothing from the app. What the Mac does with the
/// op is `VisualStubRefusalTests`.
final class VisualWireCodingTests: XCTestCase {
    private let intake = UUID()

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    static let ref = WireVisualRef(
        id: "pairing-handshake", revision: 3, kinds: ["diagram", "canvas"],
        alternates: [WireVisualAlternate(revision: 2, kind: "canvas", reason: "closer to the comp")],
        states: ["idle", "paired"])

    // MARK: - Projection

    func testAVisualRefRoundTripsUnderTheSpecsNames() throws {
        XCTAssertEqual(try JSONDecoder().decode(WireVisualRef.self, from: JSONEncoder().encode(Self.ref)), Self.ref)
        XCTAssertEqual(Set(try object(Self.ref).keys), ["id", "revision", "kinds", "alternates", "states"])
        XCTAssertEqual(Self.ref.id, "pairing-handshake", "Identifiable by the visual's id")
    }

    func testAVisualRefWithOnlyIdAndRevisionStillLoads() throws {
        let ref = try JSONDecoder().decode(WireVisualRef.self, from: Data(#"{"id":"x","revision":1}"#.utf8))
        XCTAssertEqual(ref, WireVisualRef(id: "x", revision: 1))
    }

    /// An older Mac's plan has no `visuals`; it decodes as nil, and writing it back adds nothing.
    func testAnOldMacsPlanPayloadWithNoVisualsDecodes() throws {
        let old = ##"{"checkpoint":2,"roundName":"Draft","editsVersion":"e1","markdown":"# P","outline":[],"notes":[]}"##
        let plan = try JSONDecoder().decode(WireIntakePlan.self, from: Data(old.utf8))
        XCTAssertNil(plan.visuals)
        XCTAssertNil(plan.pendingDiffs, "added after pendingDiffs: the thread fields are untouched")
        XCTAssertNil(try object(plan)["visuals"], "absent, never null")
    }

    func testAPlanCarriesItsVisuals() throws {
        let plan = WireIntakePlan(checkpoint: 2, roundName: "Draft", editsVersion: "e1", markdown: "# P",
                                  visuals: [Self.ref])
        XCTAssertEqual(try JSONDecoder().decode(WireIntakePlan.self, from: JSONEncoder().encode(plan)), plan)
        XCTAssertNotNil(try object(plan)["visuals"])
    }

    func testTheDetailsVisualsFlagIsOffByDefaultAndAbsentFromTheWire() throws {
        let detail = WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: intake, title: "T", state: "shaping", needsAttention: false,
                                       createdAt: Date(timeIntervalSince1970: 0)),
            intent: "i", servedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(detail.visuals)
        XCTAssertNil(try object(detail)["visuals"])
    }

    // MARK: - The fetch op

    /// A read that answers with bytes on its `cid`, so a request like `file.read`, not a command.
    func testVisualFetchIsARequestUnderItsDottedOp() throws {
        let request = FleetRequest.intakeVisualFetch(id: intake, visualID: "pairing-handshake", revision: 3,
                                                     part: WireVisualPart.snapshot, offset: 0, limit: FileLimits.maxChunk)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), request)
        let obj = try object(request)
        XCTAssertEqual(obj["op"] as? String, "intake.visual.fetch")
        XCTAssertEqual(Set(obj.keys), ["op", "intake", "visualID", "revision", "part", "offset", "limit"])
        XCTAssertEqual(obj["intake"] as? String, intake.uuidString)
    }

    func testAnOmittedOffsetIsZero() throws {
        let json = #"{"op":"intake.visual.fetch","intake":"\#(intake.uuidString)","visualID":"x","revision":1,"part":"bundle","limit":10}"#
        XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: Data(json.utf8)),
                       .intakeVisualFetch(id: intake, visualID: "x", revision: 1, part: "bundle", offset: 0, limit: 10))
    }

    func testPartSpellings() {
        XCTAssertEqual(WireVisualPart.snapshot, "snapshot")
        XCTAssertEqual(WireVisualPart.bundle, "bundle")
        XCTAssertEqual(WireVisualPart.snapshot(state: "paired", size: "wide"), "snapshot@paired-wide")
        XCTAssertEqual(VisualLimits.maxBytes, 10 * 1024 * 1024)
    }

    /// The reply is the existing `fileChunk`, answered on the request's cid: no new `ServerFrame`.
    func testTheReplyIsAFileChunk() throws {
        let frame = ServerFrame.fileChunk(cid: 5, WireFileChunk(path: "pairing-handshake/r3/snapshot.png", size: 3, offset: 0,
                                                                data: Data([1, 2, 3])))
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(frame)), frame)
        XCTAssertEqual(frame.correlationID, 5)
    }
}
