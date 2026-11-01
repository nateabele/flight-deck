import XCTest
@testable import IntakeKit

/// What rounds learn about a plan's visuals (P2a V4): the blocks a plan has, the ids a change
/// set may cite, the catalogue encode reads, and the strict schema that carries `visualRefs`.
final class VisualRoundsTests: XCTestCase {
    private var root: URL!
    private var tape: TapeStore { TapeStore(intakeDirectory: root) }
    private var store: DiskVisualStore { DiskVisualStore(tape: tape) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VisualRounds-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private let plan = """
    # Plan

    ## 3. Pairing

    ```fd-visual id=pairing
    Pairing handshake: phone, Mac and hostd
    ```

    ````md
    ```fd-visual id=inside
    an example, not a block
    ```
    ````

    ## 4. Later

    ```fd-visual id=later pending
    ```

    ```fd-visual id=gone
    ```
    """

    func testBlocksAreReadInOrderWithCaptionAndSection() {
        let blocks = PlanVisualFence.blocks(in: plan)
        XCTAssertEqual(blocks.map(\.id.rawValue), ["pairing", "later", "gone"], "a block inside another fence is text")
        XCTAssertEqual(blocks[0].caption, "Pairing handshake: phone, Mac and hostd")
        XCTAssertEqual(blocks[0].section, "## 3. Pairing")
        XCTAssertTrue(blocks[1].pending)
        XCTAssertNil(blocks[1].caption)
        XCTAssertEqual(blocks[2].section, "## 4. Later")
    }

    func testAnUnclosedFenceIsNotABlock() {
        XCTAssertTrue(PlanVisualFence.blocks(in: "```fd-visual id=a\ncaption\n").isEmpty)
    }

    /// Only a non-pending block whose visual is stored may be cited; a plan with none is `Set()`.
    func testKnownVisualsAreTheStoredNonPendingBlocks() throws {
        try VisualDiskFixture.install(tape, id: "pairing")
        try VisualDiskFixture.install(tape, id: "later")
        XCTAssertEqual(PlanVisualFence.knownVisuals(plan: plan, store: store), ["pairing"])
        XCTAssertEqual(PlanVisualFence.knownVisuals(plan: "# No visuals\n", store: store), Set<String>())
        XCTAssertEqual(PlanVisualFence.knownVisuals(plan: nil, store: store), Set<String>())
    }

    /// A visual with revisions but no block state anywhere is not citable: release would export
    /// nothing for it, and a task must never cite a folder that is not written.
    func testARevisionWithNoBlockStateIsNotKnown() throws {
        try VisualDiskFixture.install(tape, id: "pairing", blockState: false)
        XCTAssertEqual(PlanVisualFence.knownVisuals(plan: plan, store: store), Set<String>())
        XCTAssertTrue(VisualCatalogue.entries(plan: plan, store: store, tape: tape).isEmpty)
    }

    /// The released checkpoint's recorded block state comes first; block.json is the fallback.
    func testTheCheckpointsBlockStateWinsForKnownAndTheCatalogue() throws {
        let id = try VisualDiskFixture.install(tape, id: "pairing", r: 1, blockState: false)
        try VisualDiskFixture.install(tape, id: "pairing", r: 2, kind: "component")
        let r1 = RevisionRef(visualID: id, r: 1)
        try FileManager.default.createDirectory(at: tape.checkpointDirectory(3), withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(CheckpointBlockStates(states: [id: BlockState(representations: [r1], primary: r1)]))
            .write(to: tape.checkpointVisualsURL(3))
        XCTAssertEqual(VisualCatalogue.entries(plan: plan, store: store, tape: tape, checkpoint: 3).first?.primaryRevision, 1)
        XCTAssertEqual(VisualCatalogue.entries(plan: plan, store: store, tape: tape).first?.primaryRevision, 2)
        XCTAssertEqual(PlanVisualFence.knownVisuals(plan: plan, store: store, checkpoint: 3), ["pairing"])
    }

    /// A polish `replace` that leaves `visualRefs` null keeps the task's refs; `[]` drops them.
    func testAReplaceWithNullVisualRefsKeepsTheOldOnes() throws {
        let refs = [VisualRef(visualID: "pairing", states: ["default"])]
        let base = ChangeSet(graphObservedAt: Date(), ops: [.createBead(NewBead(tempId: "t1", title: "A", description: "d", visualRefs: refs))])
        func refsAfter(_ replacement: [VisualRef]?) throws -> [VisualRef]? {
            let patch = ChangeSetPatch(replace: [.init(index: 0, op: .createBead(NewBead(tempId: "t1", title: "B", description: "d", visualRefs: replacement)))])
            guard case .createBead(let b) = try patch.apply(to: base).get().ops[0] else { XCTFail(); return nil }
            XCTAssertEqual(b.title, "B")
            return b.visualRefs
        }
        XCTAssertEqual(try refsAfter(nil), refs, "null is not a drop")
        XCTAssertEqual(try refsAfter([]), [], "an explicit [] drops them")
    }

    func testTheCatalogueNamesKindSectionStatesAndFiles() throws {
        try VisualDiskFixture.install(tape, id: "pairing", r: 2, states: ["default", "error"])
        let entries = VisualCatalogue.entries(plan: plan, store: store, tape: tape)
        XCTAssertEqual(entries.count, 1)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.id, "pairing")
        XCTAssertEqual(e.kind, "sequence")
        XCTAssertEqual(e.section, "## 3. Pairing")
        XCTAssertEqual(e.states, ["default", "error"])
        XCTAssertEqual(e.primaryRevision, 2)
        let dir = tape.revisionDirectory(VisualID(rawValue: "pairing")!, r: 2)
        XCTAssertEqual(e.sourcePath, dir.appendingPathComponent("diagram.mmd").path)
        XCTAssertEqual(e.snapshotPath, dir.appendingPathComponent("snapshot@default-wide.png").path)

        let text = RoundPrompts.visualsCatalogue(entries)
        XCTAssertTrue(text.contains("`pairing` — sequence: Pairing handshake: phone, Mac and hostd (under \"## 3. Pairing\")"), text)
        XCTAssertTrue(text.contains("States: default, error"), text)
        XCTAssertTrue(text.contains(e.sourcePath) && text.contains(e.snapshotPath!), text)
        XCTAssertTrue(text.contains("`visualRefs`"), text)
        XCTAssertEqual(RoundPrompts.visualsCatalogue([]), "", "a plan with no visuals reads as it always did")
    }

    /// Strict mode lists every property, so every op carries `visualRefs`; each item is
    /// `{visualID, states}` with nothing else allowed.
    func testTheStrictOpSchemaCarriesVisualRefs() throws {
        let op = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Triage.op.utf8)) as? [String: Any])
        XCTAssertTrue((op["required"] as? [String] ?? []).contains("visualRefs"))
        let props = try XCTUnwrap(op["properties"] as? [String: Any])
        let refs = try XCTUnwrap(props["visualRefs"] as? [String: Any])
        XCTAssertEqual(refs["type"] as? [String], ["array", "null"])
        let item = try XCTUnwrap(refs["items"] as? [String: Any])
        XCTAssertEqual(item["required"] as? [String], ["visualID", "states"])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        XCTAssertTrue(Triage.changeSetRulesText(observedAt: Date()).contains("`[]` drops"))
    }

    /// The flat op an agent returns decodes its refs onto the new task.
    func testAFlatCreateTaskOpDecodesItsVisualRefs() throws {
        let json = #"{"graphObservedAt":"2026-11-01T00:00:00Z","ops":[{"op":"createTask","tempId":"t1","title":"T","type":null,"priority":null,"description":"d","acceptance":null,"labels":null,"from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null,"taskKind":null,"kindProposal":null,"visualRefs":[{"visualID":"pairing","states":["default"]}]},{"op":"addEdge","tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":"new:t1","to":"new:t1","kind":"related","id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null,"taskKind":null,"kindProposal":null,"visualRefs":null}]}"#
        let cs = try ChangeSet.decode(Data(json.utf8))
        guard case .createBead(let b) = cs.ops[0] else { return XCTFail("\(cs.ops)") }
        XCTAssertEqual(b.visualRefs, [VisualRef(visualID: "pairing", states: ["default"])])
    }
}
