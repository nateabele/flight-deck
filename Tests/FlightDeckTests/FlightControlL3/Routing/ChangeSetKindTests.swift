import XCTest
import IntakeKit

/// Planning classifies each created task (spec L3-R §4). The key is `taskKind`, not `kind`: the
/// op schema is one flat object and `kind` is `addEdge`'s edge kind, whose closed enum would reject
/// every kind id (deviation 1). Intakes saved before this existed must keep decoding.
final class ChangeSetKindTests: XCTestCase {
    private func create(_ extra: String) -> String {
        #"{"op":"createBead","tempId":"n1","title":"T","type":"task","priority":2,"description":"d","acceptance":null,"labels":[],"from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null"#
            + extra + "}"
    }

    private func bead(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> NewBead? {
        let op = try IntakeJSON.decoder.decode(ChangeOp.self, from: Data(json.utf8))
        guard case .createBead(let b) = op else { XCTFail("not a create: \(op)", file: file, line: line); return nil }
        return b
    }

    func testACreateCarriesAKindId() throws {
        let b = try XCTUnwrap(try bead(create(#","taskKind":"tests","kindProposal":null"#)))
        XCTAssertEqual(b.taskKind, "tests")
        XCTAssertNil(b.kindProposal)
    }

    func testACreateCarriesAProposalWithWeightsAsAnArray() throws {
        let b = try XCTUnwrap(try bead(create(#","taskKind":null,"kindProposal":{"name":"Snapshot Tests","description":"Golden files","dimensions":[{"dimension":"test-authoring","weight":0.8},{"dimension":"agentic-coding","weight":0.3}]}"#)))
        XCTAssertNil(b.taskKind)
        XCTAssertEqual(b.kindProposal, KindProposal(name: "Snapshot Tests", description: "Golden files",
                                                    dimensions: ["test-authoring": 0.8, "agentic-coding": 0.3]))
    }

    func testAnOpFromBeforeKindsStillDecodes() throws {
        let b = try XCTUnwrap(try bead(create("")))
        XCTAssertNil(b.taskKind); XCTAssertNil(b.kindProposal)
    }

    func testAnEmptyKindIdIsNoKind() throws {
        XCTAssertNil(try XCTUnwrap(try bead(create(#","taskKind":"","kindProposal":null"#))).taskKind)
    }

    func testEncodingOmitsAbsentKindsAndRoundTrips() throws {
        let plain = ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 1_790_000_000),
                              ops: [.createBead(NewBead(tempId: "n1", title: "T", description: "d"))])
        XCTAssertFalse(String(decoding: try plain.encoded(), as: UTF8.self).contains("taskKind"),
                       "a change set with no kinds encodes exactly as before")
        let kinded = ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 1_790_000_000), ops: [
            .createBead(NewBead(tempId: "n1", title: "T", description: "d", taskKind: "tests")),
            .createBead(NewBead(tempId: "n2", title: "U", description: "e",
                                kindProposal: KindProposal(name: "Snapshot Tests", description: "x", dimensions: ["test-authoring": 0.8]))),
        ])
        XCTAssertEqual(try ChangeSet.decode(kinded.encoded()), kinded)
    }

    func testTheEdgeKindIsUntouched() throws {
        let edge = #"{"op":"addEdge","tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":"new:n1","to":"b1","kind":"blocks","id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null,"taskKind":null,"kindProposal":null}"#
        XCTAssertEqual(try IntakeJSON.decoder.decode(ChangeOp.self, from: Data(edge.utf8)),
                       .addEdge(from: .new("n1"), to: .existing("b1"), kind: .blocks))
    }

    func testTheSchemaOffersBothFieldsOnTheOp() throws {
        let fragment = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Triage.changeSetSchemaFragment.utf8)) as? [String: Any])
        let ops = try XCTUnwrap((fragment["properties"] as? [String: Any])?["ops"] as? [String: Any])
        let op = try XCTUnwrap(ops["items"] as? [String: Any])
        let required = Set(op["required"] as? [String] ?? [])
        XCTAssertTrue(required.isSuperset(of: ["taskKind", "kindProposal"]))
        let props = try XCTUnwrap(op["properties"] as? [String: Any])
        XCTAssertEqual(Set(props.keys), required, "strict mode: every property required")
        let edgeKinds = try XCTUnwrap((props["kind"] as? [String: Any])?["enum"] as? [Any])
        XCTAssertEqual(edgeKinds.compactMap { $0 as? String }, ["blocks", "related", "parent-child"], "the edge kind's enum is untouched")
        let proposal = try XCTUnwrap(props["kindProposal"] as? [String: Any])
        XCTAssertEqual(proposal["type"] as? [String], ["object", "null"])
        XCTAssertEqual(proposal["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(proposal["required"] as? [String] ?? []), ["name", "description", "dimensions"])
    }
}
