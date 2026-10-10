import XCTest
import IntakeKit
@testable import FlightDeck

/// The block reaches br two ways: whole, on `br create`, and merged into whatever `agent_context`
/// already holds, on a re-route. Other keys are br's governing instructions and must survive
/// (L3-0 §4); a pinned block is never touched; and br's own shrink guard must not make a
/// re-route fail silently.
@MainActor
final class BeadWriterBlockTests: XCTestCase {
    private typealias D = RoutingTestData

    private func block(model: String = "gpt-6-sol", reason: String = "test-authoring 0.8 → codex",
                       pinned: Bool = false) -> ExecutionBlock {
        ExecutionBlock(kind: "snapshot-tests", agent: .codex, model: model, knobs: ["effort": "high"], pool: "codex-default",
                       source: AssignmentSource(by: .rule, ruleId: "r3", reason: reason, at: D.at), pinned: pinned)
    }

    private func show(_ context: String?) throws -> String {
        var row: [String: Any] = ["id": "b1", "title": "T", "status": "open"]
        if let context { row["agent_context"] = context }
        return String(decoding: try JSONSerialization.data(withJSONObject: [row]), as: UTF8.self)
    }

    private func argument(_ flag: String, in call: [String]) -> String? {
        call.firstIndex(of: flag).map { call[$0 + 1] }
    }

    func testACreateCarriesItsRoutedContext() async throws {
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)])
        let ctx = try ExecutionBlockCodec.encode(block(), into: nil)
        let out = await BeadWriter(runner: r, brPath: "br", actor: "a")
            .apply([.create(NewBead(tempId: "n1", title: "T", description: "d"))], project: "/p", agentContexts: ["n1": ctx])
        XCTAssertNil(out.error)
        let create = try XCTUnwrap(r.calls.first)
        XCTAssertEqual(argument("--agent-context", in: create), ctx)
        XCTAssertLessThan(try XCTUnwrap(create.firstIndex(of: "--agent-context")), try XCTUnwrap(create.firstIndex(of: "--actor")))
    }

    func testACreateWithoutAContextIsUnchanged() async {
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)])
        _ = await BeadWriter(runner: r, brPath: "br", actor: "a")
            .apply([.create(NewBead(tempId: "n1", title: "T", description: "d"))], project: "/p")
        XCTAssertEqual(r.calls.first, ["br", "create", "--title", "T", "-t", "task", "-p", "2", "--description", "d",
                                       "--actor", "a", "--json"])
    }

    func testWriteBlockMergesIntoTheExistingContext() async throws {
        let old = try ExecutionBlockCodec.encode(block(model: "gpt-6-luna"),
                                                 into: #"{"instructions":"keep me","flight_deck":{"notes":"keep"}}"#)
        let r = RecordingRunner(replies: ["br show": (try show(old), 0), "br update": ("", 0)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "flightdeck-routing").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertEqual(result, .written)
        let update = try XCTUnwrap(r.calls.last)
        XCTAssertEqual(Array(update.prefix(3)), ["br", "update", "b1"])
        let written = try XCTUnwrap(argument("--agent-context", in: update))
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: written).get()?.model, "gpt-6-sol")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        XCTAssertEqual(obj["instructions"] as? String, "keep me")
        XCTAssertEqual((obj["flight_deck"] as? [String: Any])?["notes"] as? String, "keep")
        XCTAssertEqual(argument("--actor", in: update), "flightdeck-routing")
        XCTAssertFalse(update.contains("--force"))
    }

    func testWriteBlockLeavesAPinnedBlockAlone() async throws {
        let r = RecordingRunner(replies: ["br show": (try show(try ExecutionBlockCodec.encode(block(pinned: true), into: nil)), 0)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(model: "gpt-6-luna"), id: "b1", project: "/p")
        XCTAssertEqual(result, .skippedPinned)
        XCTAssertEqual(r.calls.count, 1, "no update after reading a pinned block")
    }

    func testWriteBlockForcesOnlyWhenTheContextShrinksBelowHalf() async throws {
        let long = try ExecutionBlockCodec.encode(block(reason: String(repeating: "a very long reason ", count: 40)), into: nil)
        let r = RecordingRunner(replies: ["br show": (try show(long), 0), "br update": ("", 0)])
        _ = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertTrue(try XCTUnwrap(r.calls.last).contains("--force"), "br refuses a write under half the old length without it")

        let same = try ExecutionBlockCodec.encode(block(model: "gpt-6-luna"), into: nil)
        let r2 = RecordingRunner(replies: ["br show": (try show(same), 0), "br update": ("", 0)])
        _ = await BeadWriter(runner: r2, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertFalse(try XCTUnwrap(r2.calls.last).contains("--force"), "--force also bypasses br's blocked-task guard; only when needed")

        XCTAssertTrue(BeadWriter.shrinksBelowHalf(old: "1234567890", new: "1234"))
        XCTAssertFalse(BeadWriter.shrinksBelowHalf(old: "12345678", new: "1234"), "exactly half passes br's guard")
        XCTAssertFalse(BeadWriter.shrinksBelowHalf(old: nil, new: "x"))
    }

    func testWriteBlockRefusesAContextThatIsNotAnObject() async throws {
        let r = RecordingRunner(replies: ["br show": (try show(#""a bare string""#), 0)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertEqual(result, .failed("route b1: agent_context is not a JSON object"))
        XCTAssertEqual(r.calls.count, 1)
    }

    func testWriteBlockRefusesABlockFromANewerFlightDeck() async throws {
        let r = RecordingRunner(replies: ["br show": (try show(#"{"flight_deck":{"execution":{"v":2}}}"#), 0)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertEqual(result, .failed("route b1: written by a newer Flight Deck (v2)"))
    }

    func testAShowFailureIsReported() async {
        let r = RecordingRunner(replies: ["br show": ("database is locked", 1)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertEqual(result, .failed("route b1: exit 1: database is locked"))
    }

    func testTheEncodeOutputLandsAsAgentContextArgv() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BeadWriterBlockTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let steps = try RoutingFixtures.encodeSteps()
        let router = RuleRouter(rules: StaticRuleSource(global: [D.r3(pool: "codex-default")]), kinds: KindRegistryStore(),
                                index: NullCapabilityIndex(), pools: DefaultPoolDirectory(agents: [.codex, .claude]),
                                defaultAgent: { _ in .claude })
        let routed = EncodeRouting.route(steps, project: dir, registry: KindRegistryStore(), router: router, catalogs: D.catalogs, now: D.at)
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br dep": ("", 0), "br sync": ("", 0)])
        let out = await BeadWriter(runner: r, brPath: "br", actor: "a").apply(steps, project: dir.path, agentContexts: routed.contexts)
        XCTAssertNil(out.error)
        let creates = r.calls.filter { $0.prefix(2) == ["br", "create"] }
        XCTAssertEqual(creates.count, 3)
        XCTAssertTrue(creates.allSatisfy { $0.contains("--agent-context") })
        let renderer = try XCTUnwrap(creates.first { $0.contains("Snapshot tests for the renderer") })
        let written = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: argument("--agent-context", in: renderer)).get())
        XCTAssertEqual(written.kind, "snapshot-tests")
        XCTAssertEqual(written.agent, .codex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: KindRegistryStore.fileURL(project: dir).path),
                      "the proposal reached the project's kinds.json")
    }
}
