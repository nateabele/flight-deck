import XCTest
import IntakeKit

/// The swarm record is the one thing that survives a relaunch, so its JSON has to round-trip
/// exactly, and the config key — what decides that two agents are interchangeable for reuse —
/// must not depend on the order knobs happened to be written in.
final class SwarmRecordTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func block(model: String = "gpt-6-sol", knobs: [String: String] = ["effort": "high"],
                       pool: PoolID = "codex-subs") -> ExecutionBlock {
        ExecutionBlock(kind: "tests", harness: "codex", model: model, knobs: knobs, pool: pool,
                       source: AssignmentSource(by: .rule, ruleId: "r1", reason: "r", at: at))
    }

    func testConfigKeyIsHarnessModelKnobsPool() {
        XCTAssertEqual(ConfigKey(block()).rawValue, "codex|gpt-6-sol|effort=high|codex-subs")
        XCTAssertEqual(ConfigKey(block(knobs: [:])).rawValue, "codex|gpt-6-sol||codex-subs")
    }

    func testConfigKeyIgnoresKnobOrder() {
        let a = block(knobs: ["effort": "high", "agent": "build"])
        let b = block(knobs: ["agent": "build", "effort": "high"])
        XCTAssertEqual(ConfigKey(a), ConfigKey(b))
        XCTAssertEqual(ConfigKey(a).rawValue, "codex|gpt-6-sol|agent=build,effort=high|codex-subs")
    }

    func testConfigKeyDiffersOnPoolOrModel() {
        XCTAssertNotEqual(ConfigKey(block()), ConfigKey(block(pool: "codex-team")))
        XCTAssertNotEqual(ConfigKey(block()), ConfigKey(block(model: "gpt-6-terra")))
    }

    func testFilterCodesAsSpecShapes() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let intake = try JSONEncoder().encode(SwarmFilter.intake(id: id, tasks: ["fx-a"]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: intake) as? [String: Any])
        XCTAssertEqual(obj["intake"] as? String, id.uuidString)
        XCTAssertEqual(obj["tasks"] as? [String], ["fx-a"])
        XCTAssertEqual(try JSONDecoder().decode(SwarmFilter.self, from: intake), .intake(id: id, tasks: ["fx-a"]))
        let all = try JSONEncoder().encode(SwarmFilter.allReady)
        XCTAssertEqual(String(decoding: all, as: UTF8.self), #"{"allReady":true}"#)
        XCTAssertEqual(try JSONDecoder().decode(SwarmFilter.self, from: all), .allReady)
        XCTAssertThrowsError(try JSONDecoder().decode(SwarmFilter.self, from: Data("{}".utf8)))
    }

    func testFilterAdmits() {
        XCTAssertTrue(SwarmFilter.allReady.admits("anything"))
        XCTAssertTrue(SwarmFilter.intake(id: UUID(), tasks: ["fx-a"]).admits("fx-a"))
        XCTAssertFalse(SwarmFilter.intake(id: UUID(), tasks: ["fx-a"]).admits("fx-b"))
    }

    func testRecordRoundTripsWithBlockAndLease() throws {
        let lease = AccountLease(id: UUID(), pool: "codex-subs",
                                 account: AccountRef(harness: "codex", id: UUID(), label: "Work"))
        let agent = SwarmAgentRecord(session: UUID(), agentName: "BlueLake", block: block(),
                                     lease: lease, task: "fx-a", state: .working, stateSince: at)
        let record = SwarmRecord(id: UUID(), project: "/p", cap: 3, poolCaps: ["codex-subs": 2],
                                 filter: .allReady, state: .running, agents: [agent], createdAt: at)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(SwarmRecord.self, from: enc.encode(record))
        XCTAssertEqual(back, record)
        XCTAssertEqual(back.agents.first?.lease?.lease, lease)
        XCTAssertEqual(back.agents.first?.config, ConfigKey(block()))
    }

    func testActiveCountAndPoolLoadCountOnlyStartingAndWorking() {
        func agent(_ state: SwarmAgentState, pool: PoolID = "codex-subs") -> SwarmAgentRecord {
            SwarmAgentRecord(session: UUID(), agentName: "A", block: block(pool: pool), lease: nil,
                             task: nil, state: state, stateSince: at)
        }
        let record = SwarmRecord(id: UUID(), project: "/p", cap: 3, poolCaps: [:], filter: .allReady,
                                 state: .running,
                                 agents: [agent(.starting), agent(.working), agent(.idle),
                                          agent(.done), agent(.handedOff), agent(.working, pool: "other")],
                                 createdAt: at)
        XCTAssertEqual(record.activeCount, 3)
        XCTAssertEqual(record.load(of: "codex-subs"), 2)
        XCTAssertEqual(record.load(of: "other"), 1)
        XCTAssertNil(record.poolCap("codex-subs"))
    }

    func testUpdateMutatesOneAgentInPlace() {
        let s = UUID()
        var record = SwarmRecord(id: UUID(), project: "/p", cap: 1, poolCaps: [:], filter: .allReady,
                                 state: .running,
                                 agents: [SwarmAgentRecord(session: s, agentName: "A", block: block(),
                                                           lease: nil, task: nil, state: .idle, stateSince: at)],
                                 createdAt: at)
        record.update(s) { $0.task = "fx-a"; $0.state = .working }
        XCTAssertEqual(record.agent(s)?.task, "fx-a")
        XCTAssertEqual(record.agent(s)?.state, .working)
        record.update(UUID()) { $0.task = "nope" }   // unknown session: a no-op, not a crash
        XCTAssertEqual(record.agents.count, 1)
    }
}
