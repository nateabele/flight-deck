import IntakeKit
import XCTest

final class ChangeSetPatchTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_789_000_000)
    private let pre = Precondition(status: "open", assignee: nil)
    private func task(_ t: String) -> ChangeOp { .createBead(NewBead(tempId: t, title: t.uppercased(), description: "d")) }
    private func edge(_ a: String, _ b: String, _ kind: EdgeKind = .blocks) -> ChangeOp {
        .addEdge(from: BeadRef(parsing: a), to: BeadRef(parsing: b), kind: kind)
    }
    private func base(_ ops: [ChangeOp]) -> ChangeSet { ChangeSet(graphObservedAt: at, ops: ops) }

    func testReplacesRemovesAndAddsInPlaceKeepingTheRest() throws {
        let b = base([task("a"), task("b"), task("c"), task("d")])
        let revised = ChangeOp.createBead(NewBead(tempId: "b", title: "Better B", description: "more"))
        let patch = ChangeSetPatch(remove: [2], replace: [.init(index: 1, op: revised)], add: [task("e")])
        let out = try patch.apply(to: b).get()
        XCTAssertEqual(out.ops, [task("a"), revised, task("d"), task("e")])
        XCTAssertEqual(out.graphObservedAt, at)
    }

    func testAnEmptyPatchChangesNothing() throws {
        let b = base([task("a"), edge("new:a", "fd-1")])
        XCTAssertEqual(try ChangeSetPatch().apply(to: b).get(), b)
    }

    func testRefusesAnIndexOutOfRangeOrNamedTwice() {
        let b = base([task("a"), task("b")])
        let patch = ChangeSetPatch(remove: [1, 5], replace: [.init(index: 1, op: task("x")), .init(index: -1, op: task("y"))])
        guard case .failure(let problems) = patch.apply(to: b) else { return XCTFail("applied") }
        XCTAssertEqual(problems.problems, [.outOfRange(5, count: 2), .namedTwice(1), .outOfRange(-1, count: 2)])
        XCTAssertEqual(ChangeSetPatch.Problem.outOfRange(5, count: 2).message,
                       "index 5 is not in the change set (its ops are numbered 0 to 1)")
    }

    /// Dedup merges `b` into `a`: edges that named `b` name `a`, and the edge that became
    /// `a → a`, or a repeat of one already there, is dropped rather than left to fail validation.
    func testRedirectRewiresEdgesAndDropsWhatMergingLeavesBehind() throws {
        let b = base([task("a"), task("b"), task("c"),
                      edge("new:c", "new:a"), edge("new:c", "new:b"), edge("new:b", "new:a"), edge("new:b", "fd-1"),
                      edge("new:c", "new:b", .related)])
        let patch = ChangeSetPatch(remove: [1], redirect: [.init(from: "new:b", to: "new:a")])
        let out = try patch.apply(to: b).get()
        XCTAssertEqual(out.ops, [task("a"), task("c"), edge("new:c", "new:a"), edge("new:a", "fd-1"), edge("new:c", "new:a", .related)])
    }

    func testRedirectsChainAndACycleDoesNotSpin() throws {
        let b = base([task("a"), edge("new:x", "fd-1")])
        let chained = ChangeSetPatch(redirect: [.init(from: "new:x", to: "new:y"), .init(from: "new:y", to: "new:a")])
        XCTAssertEqual(try chained.apply(to: b).get().ops.last, edge("new:a", "fd-1"))
        let cycle = ChangeSetPatch(redirect: [.init(from: "new:x", to: "new:y"), .init(from: "new:y", to: "new:x")])
        XCTAssertNoThrow(try cycle.apply(to: b).get())
        guard case .failure(let p) = ChangeSetPatch(redirect: [.init(from: "new:a", to: "new:a")]).apply(to: b) else {
            return XCTFail("applied")
        }
        XCTAssertEqual(p.problems, [.selfRedirect("new:a")])
    }

    /// What the agent reads: each op under its index, in the shape a `replace` entry takes —
    /// so an entry copied out of the file decodes as one.
    func testNumberedPutsEachOpUnderItsIndex() throws {
        let b = base([task("a"), edge("new:a", "fd-1")])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try ChangeSetPatch.numbered(b)) as? [String: Any])
        let ops = try XCTUnwrap(object["ops"] as? [[String: Any]])
        XCTAssertEqual(ops.map { $0["index"] as? Int }, [0, 1])
        XCTAssertNotNil(object["graphObservedAt"])
        let entry = try JSONSerialization.data(withJSONObject: ops[1])
        XCTAssertEqual(try IntakeJSON.decoder.decode(ChangeSetPatch.Replacement.self, from: entry),
                       .init(index: 1, op: edge("new:a", "fd-1")))
    }

    /// The reply decodes from what a strict-schema model writes: every op field present, the
    /// unused ones null.
    func testOutputDecodesFromStrictSchemaJSON() throws {
        let json = #"""
        {"patch":{"remove":[2],"redirect":[{"from":"new:b","to":"new:a"}],
          "replace":[{"index":0,"op":{"op":"editTask","id":"fd-1","set":{"title":"T","description":null,"acceptance":null,"priority":null},
            "pre":{"status":"open","assignee":null},"delivery":null,"tempId":null,"title":null,"type":null,"priority":null,
            "description":null,"acceptance":null,"labels":null,"from":null,"to":null,"kind":null,"reason":null,"of":null,
            "taskKind":null,"kindProposal":null}}],
          "add":[]},"summary":"s"}
        """#
        let out = try RoundPrompts.decode(ChangeSetPatchOutput.self, Data(json.utf8))
        XCTAssertEqual(out.patch.remove, [2])
        XCTAssertEqual(out.patch.replace.first?.op, .editBead(id: "fd-1", set: FieldSet(title: "T"), pre: pre, delivery: nil))
        XCTAssertEqual(out.patch.redirect, [.init(from: "new:b", to: "new:a")])
    }
}
