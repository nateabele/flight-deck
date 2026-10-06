import FleetKit
import XCTest
@testable import FlightDeck

/// Fixtures copy claude 2.1.289's real record shapes: every subagent record is a sidechain,
/// and `meta.json` carries `agentType`/`description`/`parentAgentId`. 7cdecd26 shipped a check
/// whose fixtures left `isSidechain` out and so passed while finding nothing live.
final class SubagentTreeTests: XCTestCase {
    private func assistantText(_ text: String) -> String {
        #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    private func toolUse(_ id: String) -> String {
        #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"ls"}}]}}"#
    }
    private func toolResult(_ id: String) -> String {
        #"{"isSidechain":true,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#
    }
    private func userText(_ text: String) -> String {
        #"{"isSidechain":true,"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }
    private func lines(_ raw: [String]) -> [SourceLine] {
        raw.enumerated().map { SourceLine(offset: $0.offset * 100, text: $0.element) }
    }

    func testValidAgentIDs() {
        XCTAssertTrue(SubagentID.isValid("a28ad87bc9c01d113"))
        XCTAssertFalse(SubagentID.isValid("../etc/passwd"))
        XCTAssertFalse(SubagentID.isValid("a28ad87/../x"))
        XCTAssertFalse(SubagentID.isValid(""))
        XCTAssertFalse(SubagentID.isValid("A28AD87BC9"))
    }

    func testAFinishedTurnIsDone() {
        XCTAssertEqual(SubagentFiles.state(ofTail: lines([toolUse("t1"), toolResult("t1"),
                                                         assistantText("All done.")])), .done)
    }

    func testAnOpenCallIsRunningNotBlocked() {
        // Blocked is attribution's call (Task 4/5), never the file's: a running Bash looks
        // identical to a call waiting on a dialog.
        XCTAssertEqual(SubagentFiles.state(ofTail: lines([toolUse("t1")])), .running)
    }

    func testAResumeAfterDoneIsRunningAgain() {
        XCTAssertEqual(SubagentFiles.state(ofTail: lines([assistantText("done"),
                                                         userText("Also check X.")])), .running)
    }

    func testMetaParsesTheRealKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agent-a1.meta.json")
        try #"{"agentType":"implementer","description":"Implement Task 14","toolUseId":"toolu_1","parentAgentId":"a0","spawnDepth":2,"model":"sonnet","requestShape":"background","requestNonInteractive":true}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SubagentFiles.meta(at: url),
                       SubagentMeta(type: "implementer", description: "Implement Task 14", parentID: "a0"))
    }

    func testBuildNestsChildrenAndHangsOrphansFromTheRoot() {
        let now = Date()
        let tree = SubagentTree.build(
            metas: ["a0": .init(type: "general-purpose", description: "Controller", parentID: nil),
                    "a1": .init(type: "implementer", description: "Task 14", parentID: "a0"),
                    "a2": .init(type: "reviewer", description: "Review", parentID: "aGONE")],
            states: ["a0": (.running, now), "a1": (.running, now), "a2": (.running, now)],
            keepDoneSince: nil
        )
        XCTAssertEqual(tree.node("a1")?.parentID, "a0")
        XCTAssertNil(tree.node("a2")?.parentID, "a parent out of scope hangs the child from the root")
        XCTAssertEqual(tree.liveTopLevelCount, 2)
        XCTAssertEqual(tree.path(to: "a1"), ["a0", "a1"])
    }

    func testDoneNodesOlderThanTheCutoffAreDropped() {
        let cutoff = Date()
        let tree = SubagentTree.build(
            metas: ["old": .init(type: "t", description: "d", parentID: nil),
                    "new": .init(type: "t", description: "d", parentID: nil)],
            states: ["old": (.done, cutoff.addingTimeInterval(-60)),
                     "new": (.done, cutoff.addingTimeInterval(60))],
            keepDoneSince: cutoff
        )
        XCTAssertNil(tree.node("old"))
        XCTAssertEqual(tree.node("new")?.state, .done)
        XCTAssertEqual(tree.liveTopLevelCount, 0)
    }

    func testANodeWithoutMetaIsSkipped() {
        let tree = SubagentTree.build(metas: [:], states: ["a1": (.running, Date())],
                                      keepDoneSince: nil)
        XCTAssertTrue(tree.nodes.isEmpty)
    }

    func testMarkingBlockedOnlyTouchesThatNode() {
        let now = Date()
        let tree = SubagentTree.build(
            metas: ["a1": .init(type: "implementer", description: "d", parentID: nil),
                    "a2": .init(type: "reviewer", description: "d", parentID: nil)],
            states: ["a1": (.running, now), "a2": (.running, now)], keepDoneSince: nil
        ).marking(blocked: "a1", call: "toolu_X")
        XCTAssertEqual(tree.node("a1")?.state, .blocked(callID: "toolu_X"))
        XCTAssertEqual(tree.node("a2")?.state, .running)
    }
}
