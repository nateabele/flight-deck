import XCTest
import IntakeKit
@testable import FlightDeck

/// Unify brief R1: `Harness`, `ModelFamily` and `HarnessID` collapsed into one `AgentID`, and the
/// Swift names moved from `harness` to `agent` — but every file on disk still spells the agent
/// under the JSON key `harness`, with the same raw values. These decode the OLD shapes, written
/// out by hand exactly as earlier builds wrote them, and check that re-encoding keeps the key:
/// a renamed key would make every intake, tape, routing file and preferences blob on disk fail
/// to decode, and `preferences.v1` fails silently (`try?`) into a full reset.
final class AgentIdentityDecodingTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: intake.json

    func testAnIntakeWithHarnessKeysDecodesToAgents() throws {
        let intake = json("""
        {"id":"12345678-1234-5678-1234-567812345678","projectPath":"/p","intent":"add a tooltip",
         "createdAt":"2026-09-20T12:00:00Z","state":"shaping","recommended":"sketch",
         "recommendationReason":"small","ratingOverrides":{},"droppedOps":[],"confirmedDrift":[],
         "exchanges":[],
         "triage":{"harness":"codex","sessionID":"s-1","model":"gpt-6-sol","effort":"high"},
         "roundConfig":{"drafters":[{"choice":{"harness":"grok","model":"grok-4.6","effort":"high"},"persona":"general",
                                     "fallback":{"harness":"claude","model":"opus","effort":"high"}}],
                        "reviewer":{"choice":{"harness":"gemini","model":"gemini-3.1-pro-high","effort":""},"persona":"general"},
                        "integrator":{"harness":"claude","model":"opus","effort":"high"},
                        "encoder":{"harness":"codex","model":"gpt-6-sol","effort":"high"},
                        "refinementCap":2,"polishCap":0,"freshEyesAndDedup":false,"defaultPlay":"toReview","customized":false}}
        """)
        let decoded = try IntakeJSON.decoder.decode(Intake.self, from: intake)
        XCTAssertEqual(decoded.triage?.agent, .codex)
        let config = try XCTUnwrap(decoded.roundConfig)
        XCTAssertEqual(config.drafters.first?.choice.agent, .grok)
        XCTAssertEqual(config.drafters.first?.fallback?.agent, .claude)
        XCTAssertEqual(config.reviewer?.choice.agent, .gemini)
        XCTAssertEqual(config.integrator.agent, .claude)
        XCTAssertEqual(config.encoder.agent, .codex)

        let reencoded = try object(IntakeJSON.encoder.encode(decoded))
        let triage = try XCTUnwrap(reencoded["triage"] as? [String: Any])
        XCTAssertEqual(triage["harness"] as? String, "codex", "the key an older build reads")
        XCTAssertNil(triage["agent"])
        let integrator = try XCTUnwrap((reencoded["roundConfig"] as? [String: Any])?["integrator"] as? [String: Any])
        XCTAssertEqual(integrator["harness"] as? String, "claude")
    }

    // MARK: Tapes

    func testATapeSlotOutcomeWithHarnessKeysDecodes() throws {
        let slot = json("""
        {"role":"drafter","persona":"general","status":"substituted","sessionID":"x",
         "used":{"harness":"claude","model":"opus","effort":"high"},
         "requested":{"harness":"grok","model":"grok-4.6","effort":"high"}}
        """)
        let decoded = try IntakeJSON.decoder.decode(SlotOutcome.self, from: slot)
        XCTAssertEqual(decoded.used.agent, .claude)
        XCTAssertEqual(decoded.requested.agent, .grok)
        let used = try XCTUnwrap(try object(IntakeJSON.encoder.encode(decoded))["used"] as? [String: Any])
        XCTAssertEqual(used["harness"] as? String, "claude")
    }

    /// A runner from an older build may still be writing `activity.json` for a round this build
    /// draws.
    func testSeatActivityKeepsItsHarnessKey() throws {
        let activity = SeatActivity(agent: .gemini, startedAt: Date(timeIntervalSince1970: 0))
        let encoded = try object(IntakeJSON.encoder.encode(activity))
        XCTAssertEqual(encoded["harness"] as? String, "gemini")
        XCTAssertNotNil(encoded["footprint"], "every other key still encodes")
        XCTAssertEqual(try IntakeJSON.decoder.decode(SeatActivity.self, from: IntakeJSON.encoder.encode(activity)), activity)
    }

    // MARK: preferences.v1

    /// A real pre-unification blob: the rule compiler, a capacity pool and a project's account
    /// assignment, all spelled the old way.
    private func legacyPreferences(work: UUID, spare: UUID) throws -> Data {
        var blob = try object(JSONEncoder().encode(Preferences()))
        blob["storedAccounts"] = [
            ["id": work.uuidString, "agent": "claude", "displayName": "Work", "home": "file:///tmp/fd-unify/w/"],
            ["id": spare.uuidString, "agent": "claude", "displayName": "Spare", "home": "file:///tmp/fd-unify/s/"],
        ]
        blob["flightControlRouting"] = [
            "globalRules": [],
            "compiler": ["harness": "codex", "model": "gpt-6-sol", "effort": "low"],
        ]
        blob["capacity"] = [
            "pools": [[
                "id": "pool-night001", "label": "Night", "harness": "claude", "kind": "hosted",
                "accounts": [spare.uuidString], "softThreshold": 0.7, "hardThreshold": 0.9, "concurrencyCap": 2,
            ]],
            "confirmHandoffs": false,
        ]
        blob["storedProjectSettings"] = ["/p": ["accounts": ["claude": work.uuidString], "options": [:]]]
        return try JSONSerialization.data(withJSONObject: blob)
    }

    func testAPreUnificationPreferencesBlobDecodes() throws {
        let work = UUID(), spare = UUID()
        let decoded = try JSONDecoder().decode(Preferences.self, from: legacyPreferences(work: work, spare: spare))
        XCTAssertEqual(decoded.flightControlRouting?.compiler?.agent, .codex)
        XCTAssertEqual(decoded.capacity?.pools?.first?.agent, .claude)
        XCTAssertEqual(decoded.projectSettings["/p"]?.accounts[.claude], .account(work),
                       "an account id stored before pools existed is an account assignment")
        XCTAssertNil(decoded.storedAccountList, "never migrated yet")
    }

    func testTheCompilerSettingsKeepTheHarnessKey() throws {
        let encoded = try object(JSONEncoder().encode(RuleCompilerSettings(agent: .codex)))
        XCTAssertEqual(encoded["harness"] as? String, "codex")
        XCTAssertNil(encoded["agent"])
    }

    func testACapacityPoolKeepsTheHarnessKey() throws {
        let pool = CapacityPool.hosted(id: "pool-a", label: "A", agent: .codex, accounts: [])
        let encoded = try object(JSONEncoder().encode(pool))
        XCTAssertEqual(encoded["harness"] as? String, "codex")
        XCTAssertEqual(try JSONDecoder().decode(CapacityPool.self, from: JSONEncoder().encode(pool)), pool)
    }

    /// `HarnessID` accepted any string, and local pools named adapters like "opencode" (a real case since the OpenCode adapter; "aider" stands in
    /// for an agent no build knows). One such
    /// pool must cost that pool, not the whole `preferences.v1` (decoded with `try?`, so a throw
    /// there resets every preference).
    func testAPoolNamingAnUnknownAgentIsDroppedNotFatal() throws {
        var blob = try object(JSONEncoder().encode(Preferences()))
        blob["capacity"] = ["pools": [
            ["id": "pool-local001", "label": "Ollama", "harness": "aider", "kind": "local", "accounts": [],
             "softThreshold": 0.8, "hardThreshold": 0.95, "endpoint": "http://localhost:11434", "concurrencyCap": 2],
            ["id": "pool-b", "label": "B", "harness": "claude", "kind": "hosted", "accounts": [],
             "softThreshold": 0.8, "hardThreshold": 0.95, "concurrencyCap": 2],
        ]]
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: blob))
        XCTAssertEqual(decoded.capacity?.pools?.map(\.id), ["pool-b"])
    }

    // MARK: ProjectSettings

    func testAccountAssignmentsKeepThePrePoolShape() throws {
        let account = UUID()
        let settings = ProjectSettings(accounts: [.claude: .account(account), .codex: .pool("pool-night001")])
        let encoded = try object(JSONEncoder().encode(settings))
        XCTAssertEqual(encoded["accounts"] as? [String: String], ["claude": account.uuidString],
                       "an older build decodes `accounts` as [AgentID: UUID]; a pool id there would fail its whole preferences decode")
        XCTAssertEqual(encoded["accountPools"] as? [String: String], ["codex": "pool-night001"])
        XCTAssertEqual(try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testNoPoolAssignmentWritesNoPoolKey() throws {
        let encoded = try object(JSONEncoder().encode(ProjectSettings(accounts: [.claude: .account(UUID())])))
        XCTAssertNil(encoded["accountPools"], "a project with no pool stays byte-compatible with an older build")
    }

    // MARK: Routing

    func testARuleKeepsTheHarnessKey() throws {
        let assign = RuleAssign(agent: .codex, model: "gpt-6-sol", pool: "codex-default")
        let encoded = try object(JSONEncoder().encode(assign))
        XCTAssertEqual(encoded["harness"] as? String, "codex")
    }

    /// A rule naming an agent this build has no case for must not take the rule list with it.
    func testARuleNamingAnUnknownAgentDegradesToFailed() throws {
        let rules = json("""
        [{"id":"r1","sentence":"use aider for docs","state":"confirmed",
          "compiled":{"match":{"any":[{"dimension":"docs-prose","atLeast":0.5}]},
                      "assign":{"harness":"aider","model":"m","knobs":{},"pool":"p"}},
          "compiler":{"harness":"aider","model":"m"}},
         {"id":"r2","sentence":"codex for tests","state":"confirmed",
          "compiled":{"match":{"any":[{"kind":"tests"}]},"assign":{"harness":"codex","model":"gpt-6-sol","pool":"codex-default"}}}]
        """)
        let decoded = try JSONDecoder().decode([RoutingRule].self, from: rules)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertNil(decoded[0].compiled)
        XCTAssertEqual(decoded[0].state, .failed)
        XCTAssertEqual(decoded[0].failure, RoutingRule.unreadableCompileFailure)
        XCTAssertNil(decoded[0].compiler)
        XCTAssertEqual(decoded[1].compiled?.assign.agent, .codex)
        XCTAssertEqual(decoded[1].state, .confirmed)
    }

    /// An execution block naming an unknown agent is an invalid block, reported as one — it used
    /// to pass as a `HarnessID` and fail later at spawn.
    func testAnExecutionBlockNamingAnUnknownAgentIsInvalid() throws {
        let context = #"{"flight_deck":{"execution":{"v":1,"kind":"tests","harness":"aider","model":"m","pool":"p","source":{"by":"rule","reason":"r","at":"2026-10-07T00:00:00Z"}}}}"#
        let result = ExecutionBlockCodec.decode(agentContext: context)
        guard case .failure(.invalidField(let field, _)) = result else {
            return XCTFail("expected an invalid harness field, got \(String(describing: result))")
        }
        XCTAssertEqual(field, "harness")
    }

    func testAnExecutionBlockRoundTripsUnderTheHarnessKey() throws {
        let block = ExecutionBlock(kind: "tests", agent: .codex, model: "gpt-6-sol", pool: "codex-default",
                                   source: AssignmentSource(by: .rule, reason: "r", at: Date(timeIntervalSince1970: 1_790_000_000)))
        let context = try ExecutionBlockCodec.encode(block, into: nil)
        XCTAssertTrue(context.contains(#""harness":"codex""#), context)
        guard case .success(let decoded?) = ExecutionBlockCodec.decode(agentContext: context) else {
            return XCTFail("round trip failed")
        }
        XCTAssertEqual(decoded.agent, .codex)
    }

    /// The rule compiler's own output schema still calls the field `harness` — recorded compiler
    /// outputs and the prompt both use it.
    func testTheCompilerWireKeepsItsHarnessField() throws {
        let wire = json(#"{"ok":true,"reason":null,"mode":"any","terms":[],"harness":"codex","model":null,"modelDefaulted":false,"knobs":[],"pool":null,"fallbackPool":null}"#)
        XCTAssertEqual(try JSONDecoder().decode(RuleCompilerWire.self, from: wire).harness, "codex")
    }

    // MARK: Accounts and sessions

    func testAgentKeyedMapsStillEncodeAsObjects() throws {
        let encoded = try object(JSONEncoder().encode([AgentID.claude: 1, .gemini: 2]))
        XCTAssertEqual(encoded["claude"] as? Int, 1)
        XCTAssertEqual(encoded["gemini"] as? Int, 2)
    }

    func testRawValuesAreTheStorageFormat() {
        XCTAssertEqual(AgentID.allCases.map(\.rawValue), ["claude", "codex", "grok", "gemini", "opencode"])
        XCTAssertEqual(AgentID.planningOrder, [.codex, .claude, .grok, .gemini, .opencode],
                       "the old Harness.allCases order, opencode appended")
    }
}
