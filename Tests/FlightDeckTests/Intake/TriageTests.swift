import XCTest
import IntakeKit

final class TriageTests: XCTestCase {
    func testDecodesQuestions() throws {
        let d = Data(#"{"kind":"questions","questions":["Mac only?"],"preset":null,"reason":null,"changeSet":null}"#.utf8)
        XCTAssertEqual(try Triage.decode(d), .questions(["Mac only?"]))
    }
    func testDecodesBeadRecommendationWithChangeSet() throws {
        let d = Data(#"""
        {"kind":"recommendation","questions":null,"preset":"bead","reason":"one file",
         "changeSet":{"graphObservedAt":"2026-09-26T20:00:00Z","ops":[
          {"op":"createBead","tempId":"n1","title":"T","type":"task","priority":2,"description":"d","acceptance":null,"labels":[],
           "from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null}]}}
        """#.utf8)
        guard case .recommendation(let p, _, let cs) = try Triage.decode(d) else { return XCTFail() }
        XCTAssertEqual(p, .bead); XCTAssertEqual(cs?.ops.count, 1)
    }
    func testProseOutputFails() {
        XCTAssertThrowsError(try Triage.decode(Data("Sure, here's my plan".utf8)))
    }
    func testQuestionsKindWithoutQuestionsFails() {
        XCTAssertThrowsError(try Triage.decode(Data(#"{"kind":"questions","questions":null,"preset":null,"reason":null,"changeSet":null}"#.utf8)))
    }
    func testSchemaIsValidJSONAndStrict() throws {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Triage.schemaJSON.utf8)) as? [String: Any])
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(obj["required"] as? [String] ?? []), ["kind", "questions", "preset", "reason", "changeSet"])
    }
    func testPromptNamesTheInputFiles() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                                     agentsFile: "/p/AGENTS.md", readmeFile: nil, observedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(p.contains("/i/graph.json")); XCTAssertTrue(p.contains("/p/AGENTS.md"))
        XCTAssertTrue(p.contains("new:"))           // teaches the temp-id reference form
    }
    /// A project with no AGENTS.md must not send the agent off to read one.
    func testPromptOmitsAnAbsentAgentsFile() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                                     agentsFile: nil, readmeFile: nil, observedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(p.contains("agent instructions"), p)
        XCTAssertFalse(p.contains("README"), p)
    }
    func testPromptStatesPerOpRequiredFieldsAndFollowUpIsAnOp() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                                     agentsFile: "/p/AGENTS.md", readmeFile: nil, observedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(p.contains("op=followUp"))    // an op, not "add a followUp bead"
        XCTAssertTrue(p.contains("kind"))           // addEdge's required `kind` field
    }
    func testPromptCarriesFDsGraphObservedAt() {
        let observedAt = Date(timeIntervalSince1970: 1_798_920_000)
        let p = Triage.initialPrompt(intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                                     agentsFile: "/p/AGENTS.md", readmeFile: nil, observedAt: observedAt)
        XCTAssertTrue(p.contains(IntakeJSON.string(from: observedAt)))
        XCTAssertTrue(Triage.encodeNowPrompt(observedAt: observedAt).contains(IntakeJSON.string(from: observedAt)))
    }
    func testPromptDescribesGraphFileShape() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                                     agentsFile: "/p/AGENTS.md", readmeFile: nil, observedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(p.contains("dependent"))
        XCTAssertTrue(p.contains(#""assignee": null"#))
    }

    // Live probe (2026-09-26): both real CLIs accept Triage.schemaJSON as a strict schema —
    // codex via `--output-schema`, claude via `--json-schema`. These fixtures are their
    // actual stdout for the same prompt; decoding them end-to-end is what the schema is for.
    private func load(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Intake")))
    }
    func testDecodesLiveCodexOutput() throws {
        let out = try HeadlessOutput.parse(.codex, stdout: try load("triage-codex-live", "jsonl"))
        guard case .questions(let qs) = try Triage.decode(out.structured) else { return XCTFail() }
        XCTAssertEqual(qs.count, 1)
    }
    func testDecodesLiveClaudeOutput() throws {
        let out = try HeadlessOutput.parse(.claude, stdout: try load("triage-claude-live", "json"))
        guard case .questions(let qs) = try Triage.decode(out.structured) else { return XCTFail() }
        XCTAssertEqual(qs.count, 1)
    }
}
