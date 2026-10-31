import XCTest
import IntakeKit

final class TriageTests: XCTestCase {
    func testDecodesQuestions() throws {
        let d = Data(#"{"kind":"questions","questions":["Mac only?"],"preset":null,"reason":null,"changeSet":null}"#.utf8)
        XCTAssertEqual(try Triage.decode(d), .questions([.text(id: "q1", "Mac only?")]))
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
    /// What agents are told to emit now: `singleTask` and `createTask`. Same result as the old
    /// spellings the test above keeps decoding.
    func testDecodesTheNamesAgentsAreNowOffered() throws {
        let d = Data(#"""
        {"kind":"recommendation","questions":null,"preset":"singleTask","reason":"one file",
         "changeSet":{"graphObservedAt":"2026-09-26T20:00:00Z","ops":[
          {"op":"createTask","tempId":"n1","title":"T","type":"task","priority":2,"description":"d","acceptance":null,"labels":[],
           "from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null}]}}
        """#.utf8)
        guard case .recommendation(let p, _, let cs) = try Triage.decode(d) else { return XCTFail() }
        XCTAssertEqual(p, .bead)
        guard case .createBead(let t)? = cs?.ops.first else { return XCTFail() }
        XCTAssertEqual(t.tempId, "n1")
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
    /// Triage pins the scope down with the human before it recommends (the maintainer, 2026-10-13): it
    /// asks as many questions as it takes rather than as few as it can get away with, and an
    /// answer that leaves the scope open earns another round instead of a forced guess.
    func testTriageAsksAsManyQuestionsAsTheScopeNeeds() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                                     agentsFile: nil, readmeFile: nil, observedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(p.contains("Ask as many clarifying\n  questions as it takes"), p)
        XCTAssertFalse(p.contains("do not ask anything"), p)
        let answers = Triage.answersPrompt(questions: ["Which screens?"], answers: ["All of them"])
        XCTAssertTrue(answers.contains("ask your\nfollow-up questions now (kind=questions)"), answers)
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
        XCTAssertTrue(qs.allSatisfy { $0.kind == .text })
    }
    func testDecodesLiveClaudeOutput() throws {
        let out = try HeadlessOutput.parse(.claude, stdout: try load("triage-claude-live", "json"))
        guard case .questions(let qs) = try Triage.decode(out.structured) else { return XCTFail() }
        XCTAssertEqual(qs.count, 1)
        XCTAssertTrue(qs.allSatisfy { $0.kind == .text })
    }

    // MARK: structured questions

    private func decodeQuestions(_ items: String) throws -> [StructuredQuestion] {
        let d = Data(#"{"kind":"questions","questions":\#(items),"preset":null,"reason":null,"changeSet":null}"#.utf8)
        guard case .questions(let qs) = try Triage.decode(d) else { XCTFail("not questions"); return [] }
        return qs
    }
    func testDecodesStructuredQuestions() throws {
        let qs = try decodeQuestions(#"""
        [{"id":"q1","text":"Which store?","kind":"single","options":[
          {"id":"a","label":"A","detail":null},{"id":"b","label":"B","detail":"faster"},{"id":"c","label":"C","detail":null}],
          "recommended":["b"],"allowOther":true}]
        """#)
        XCTAssertEqual(qs.count, 1)
        XCTAssertEqual(qs[0].kind, .single)
        XCTAssertEqual(qs[0].options.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(qs[0].options[1].detail, "faster")
        XCTAssertEqual(qs[0].recommended, ["b"])
    }
    func testDecodesLegacyStringQuestions() throws {
        let qs = try decodeQuestions(#"["Who?"]"#)
        XCTAssertEqual(qs, [.text(id: "q1", "Who?")])
    }
    func testMalformedChoiceQuestionDegradesToText() throws {
        let qs = try decodeQuestions(#"""
        [{"id":"q1","text":"Which?","kind":"single","options":[{"id":"m","label":"Mac","detail":null}],"recommended":[],"allowOther":false}]
        """#)
        XCTAssertEqual(qs[0].kind, .text)
        XCTAssertEqual(qs[0].text, "Which? (e.g. Mac)")
        XCTAssertTrue(qs[0].options.isEmpty)
    }
    func testDuplicateIdsAreRenumbered() throws {
        let qs = try decodeQuestions(#"""
        [{"id":"x","text":"One?","kind":"single","options":[{"id":"a","label":"A","detail":null},{"id":"a","label":"B","detail":null}],"recommended":["zz"],"allowOther":false},
         {"id":"x","text":"Two?","kind":"text","options":[],"recommended":[],"allowOther":false}]
        """#)
        XCTAssertEqual(qs.map(\.id), ["q1", "q2"])
        XCTAssertEqual(qs[0].options.map(\.id), ["o1", "o2"])
        XCTAssertEqual(qs[0].recommended, [])
        XCTAssertTrue(qs[0].allowOther, "single always allows Other")
    }
    func testToggleNeedsExactlyOneOption() throws {
        let qs = try decodeQuestions(#"""
        [{"id":"q1","text":"Ok?","kind":"toggle","options":[{"id":"y","label":"Yes","detail":null},{"id":"n","label":"No","detail":null}],"recommended":[],"allowOther":false}]
        """#)
        XCTAssertEqual(qs[0].kind, .text)
    }
    func testSchemaSurvivesGeminiCompatible() throws {
        let compat = GeminiSchema.compatible(Triage.schemaJSON)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(compat.utf8)) as? [String: Any])
        let props = try XCTUnwrap(root["properties"] as? [String: Any])
        let questions = try XCTUnwrap(props["questions"] as? [String: Any])
        let item = try XCTUnwrap(questions["items"] as? [String: Any])
        let kind = try XCTUnwrap((item["properties"] as? [String: Any])?["kind"] as? [String: Any])
        XCTAssertEqual(kind["enum"] as? [String], ["single", "multi", "toggle", "text"])
        XCTAssertNil(kind["anyOf"])
    }
    func testPromptAsksForChoices() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                                     agentsFile: nil, readmeFile: nil, observedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(p.contains("`single` or `multi`"), p)
        XCTAssertTrue(p.contains("`recommended`"), p)
    }
}
