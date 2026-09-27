import XCTest
import IntakeKit

final class RoundPromptsTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_798_920_000)

    private func context(annotations: [String] = [], qa: [TriageExchange] = []) -> RoundContext {
        RoundContext(intent: "Ship the thing", qa: qa, graphFile: "/i/graph.json",
                     agentsFile: "/p/AGENTS.md", readmeFile: nil, annotations: annotations,
                     observedAt: observedAt)
    }

    /// Walks every object-shaped node in a parsed JSON Schema and asserts strict mode:
    /// `additionalProperties: false`, and `required` exactly equal to `properties`' keys.
    /// Recurses into `properties` values and array `items` — the two places a nested object
    /// can hide.
    private func assertStrict(_ node: Any, file: StaticString = #filePath, line: UInt = #line) {
        guard let obj = node as? [String: Any] else { return }
        if let props = obj["properties"] as? [String: Any] {
            XCTAssertEqual(obj["additionalProperties"] as? Bool, false,
                           "missing additionalProperties:false", file: file, line: line)
            XCTAssertEqual(Set(obj["required"] as? [String] ?? []), Set(props.keys),
                           "required does not match properties' keys", file: file, line: line)
            for value in props.values { assertStrict(value, file: file, line: line) }
        }
        if let items = obj["items"] { assertStrict(items, file: file, line: line) }
    }

    private func parse(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    // MARK: - Schemas

    func testDraftSchemaIsStrict() throws { assertStrict(try parse(RoundSchemas.draft)) }
    func testReviewSchemaIsStrict() throws { assertStrict(try parse(RoundSchemas.review)) }
    func testIntegrateSchemaIsStrict() throws { assertStrict(try parse(RoundSchemas.integrate)) }
    func testChangeSetSchemaIsStrict() throws { assertStrict(try parse(RoundSchemas.changeSet)) }

    func testChangeSetSchemaEmbedsTriageFragmentExactly() throws {
        let outer = try XCTUnwrap(try parse(RoundSchemas.changeSet) as? [String: Any])
        let props = try XCTUnwrap(outer["properties"] as? [String: Any])
        let embedded = try XCTUnwrap(props["changeSet"])
        let embeddedData = try JSONSerialization.data(withJSONObject: embedded, options: [.sortedKeys])
        let fragment = try parse(Triage.changeSetSchemaFragment)
        let fragmentData = try JSONSerialization.data(withJSONObject: fragment, options: [.sortedKeys])
        XCTAssertEqual(embeddedData, fragmentData)
    }

    /// `Triage.schemaJSON` must stay byte-identical after the refactor that extracted
    /// `changeSetSchemaFragment` out of it — this compares against a copy captured from the
    /// pre-refactor source (see task-4-report.md for how it was captured).
    func testTriageSchemaJSONUnchangedByTheRefactor() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "triage-schema", withExtension: "json", subdirectory: "Fixtures/Intake"))
        let fixture = try Data(contentsOf: url)
        XCTAssertEqual(Data(Triage.schemaJSON.utf8), fixture)
    }

    // MARK: - Draft

    func testDraftPromptNamesInputFilesAndQATranscript() {
        let qa = [TriageExchange(questions: ["Mac only?"], answers: ["Yes"])]
        let p = RoundPrompts.draft(context(qa: qa), persona: .general)
        XCTAssertTrue(p.contains("/i/graph.json"))
        XCTAssertTrue(p.contains("/p/AGENTS.md"))
        XCTAssertTrue(p.contains("Mac only?"))
        XCTAssertTrue(p.contains("Yes"))
        XCTAssertTrue(p.contains("complete, detailed, granular markdown plan"))
        XCTAssertTrue(p.contains("dependent")) // graph-shape paragraph, same as Triage's
    }

    func testDraftPromptOmitsQATranscriptWhenThereIsNone() {
        let p = RoundPrompts.draft(context(), persona: .general)
        XCTAssertFalse(p.contains("Q&A transcript"))
    }

    func testDraftPromptHasNoLensForGeneralPersona() {
        let p = RoundPrompts.draft(context(), persona: .general)
        XCTAssertFalse(p.contains("Your lens:"))
    }

    func testDraftPromptPersonaLenses() {
        XCTAssertTrue(RoundPrompts.draft(context(), persona: .arbiter).contains("global coherence"))
        XCTAssertTrue(RoundPrompts.draft(context(), persona: .realist).contains("implementability and sequencing"))
        XCTAssertTrue(RoundPrompts.draft(context(), persona: .coverage).contains("every feature, edge case and workflow"))
        XCTAssertTrue(RoundPrompts.draft(context(), persona: .stressTest).contains("challenge every assumption"))
    }

    // MARK: - Synthesis

    func testSynthesisPromptNamesDraftPathsAndAsksForOwnEdits() {
        let p = RoundPrompts.synthesis(context(), ownDraft: "/i/draft-a.md",
                                       otherDrafts: ["/i/draft-b.md", "/i/draft-c.md"])
        XCTAssertTrue(p.contains("Read-only files:"))
        XCTAssertTrue(p.contains("/i/draft-a.md"))
        XCTAssertTrue(p.contains("/i/draft-b.md"))
        XCTAssertTrue(p.contains("/i/draft-c.md"))
        XCTAssertTrue(p.contains("intellectually honest"))
    }

    // MARK: - Review

    func testReviewPromptHasOvershootPhraseAndPlanFile() {
        let p = RoundPrompts.review(context(), planFile: "/i/plan.md", round: 2)
        XCTAssertTrue(p.contains("/i/plan.md"))
        XCTAssertTrue(p.contains("at least 40 elements"))
    }

    func testReviewPromptCarriesAnnotationsWhenPresent() {
        let p = RoundPrompts.review(context(annotations: ["Keep it Mac-only"]), planFile: "/i/plan.md", round: 1)
        XCTAssertTrue(p.contains("The human steering this plan says:"))
        XCTAssertTrue(p.contains("Keep it Mac-only"))
    }

    func testReviewPromptOmitsAnnotationsHeaderWhenNone() {
        let p = RoundPrompts.review(context(), planFile: "/i/plan.md", round: 1)
        XCTAssertFalse(p.contains("The human steering this plan says:"))
    }

    // MARK: - Integrate

    func testIntegratePromptEditsOnlyThatFile() {
        let p = RoundPrompts.integrate(planFile: "/i/plan.md", changesFile: "/i/changes.json")
        XCTAssertTrue(p.contains("/i/plan.md"))
        XCTAssertTrue(p.contains("/i/changes.json"))
        XCTAssertTrue(p.contains("edit only that file"))
    }

    // MARK: - Encode

    func testEncodePromptHasObservedAtAndNeverLoseAFeature() {
        let p = RoundPrompts.encode(context(), planFile: "/i/plan.md")
        XCTAssertTrue(p.contains("/i/plan.md"))
        XCTAssertTrue(p.contains(IntakeJSON.string(from: observedAt)))
        XCTAssertTrue(p.contains("Never lose a feature"))
    }

    // MARK: - Polish

    func testPolishPromptHasDoNotOversimplifyAndObservedAt() {
        let p = RoundPrompts.polish(context(), planFile: "/i/plan.md", changeSetFile: "/i/cs.json", round: 3)
        XCTAssertTrue(p.contains("DO NOT OVERSIMPLIFY"))
        XCTAssertTrue(p.contains(IntakeJSON.string(from: observedAt)))
        XCTAssertTrue(p.contains("/i/plan.md"))
        XCTAssertTrue(p.contains("/i/cs.json"))
        XCTAssertTrue(p.contains("must stay exactly what it was"))
    }

    func testPolishPromptOmitsShadowBeadsClauseWhenNil() {
        let p = RoundPrompts.polish(context(), planFile: "/i/plan.md", changeSetFile: "/i/cs.json", round: 3)
        XCTAssertFalse(p.contains("--robot-insights"))
    }

    func testPolishPromptAddsShadowBeadsClauseWhenPresent() {
        let p = RoundPrompts.polish(context(), planFile: "/i/plan.md", changeSetFile: "/i/cs.json",
                                    round: 3, shadowBeads: "/i/shadow.db")
        XCTAssertTrue(p.contains("--db /i/shadow.db --robot-insights"))
        XCTAssertTrue(p.contains("--robot-plan"))
        XCTAssertTrue(p.contains("--robot-priority"))
        XCTAssertTrue(p.contains("restructure"))
    }

    // MARK: - Fresh eyes

    func testFreshEyesPromptOmitsShadowBeadsClauseWhenNil() {
        let p = RoundPrompts.freshEyes(context(), planFile: "/i/plan.md", changeSetFile: "/i/cs.json")
        XCTAssertTrue(p.contains("/i/plan.md"))
        XCTAssertTrue(p.contains("/i/cs.json"))
        XCTAssertTrue(p.contains("fresh"))
        XCTAssertFalse(p.contains("--robot-insights"))
        XCTAssertTrue(p.contains("must stay exactly what it was"))
    }

    func testFreshEyesPromptAddsShadowBeadsClauseWhenPresent() {
        let p = RoundPrompts.freshEyes(context(), planFile: "/i/plan.md", changeSetFile: "/i/cs.json",
                                       shadowBeads: "/i/shadow.db")
        XCTAssertTrue(p.contains("--db /i/shadow.db"))
    }

    // MARK: - Dedup

    func testDedupPromptOmitsShadowBeadsClauseWhenNil() {
        let p = RoundPrompts.dedup(context(), changeSetFile: "/i/cs.json")
        XCTAssertTrue(p.contains("/i/cs.json"))
        XCTAssertTrue(p.contains("duplicative"))
        XCTAssertFalse(p.contains("--robot-plan"))
        XCTAssertTrue(p.contains("must stay exactly what it was"))
    }

    func testDedupPromptAddsShadowBeadsClauseWhenPresent() {
        let p = RoundPrompts.dedup(context(), changeSetFile: "/i/cs.json", shadowBeads: "/i/shadow.db")
        XCTAssertTrue(p.contains("--db /i/shadow.db"))
    }

    // MARK: - decode

    func testDecodeRejectsProse() {
        XCTAssertThrowsError(try RoundPrompts.decode(DraftOutput.self, Data("Sure, here's my plan".utf8)))
    }

    func testDecodeAcceptsValidDraftOutput() throws {
        let out = try RoundPrompts.decode(DraftOutput.self, Data(#"{"plan":"the plan"}"#.utf8))
        XCTAssertEqual(out.plan, "the plan")
    }

    func testDecodeAcceptsValidChangeSetOutput() throws {
        let json = #"{"changeSet":{"graphObservedAt":"2026-09-26T20:00:00Z","ops":[]},"summary":"none"}"#
        let out = try RoundPrompts.decode(ChangeSetOutput.self, Data(json.utf8))
        XCTAssertEqual(out.summary, "none")
        XCTAssertEqual(out.changeSet.ops.count, 0)
    }

    // MARK: - Live probe fixtures (2026-09-27): real codex/claude output for RoundSchemas.review
    // and RoundSchemas.changeSet, captured once (see task-4-report.md). Decoding these
    // end-to-end is what the schema is for — a schema that merely parses proves nothing about
    // whether a real strict-mode CLI accepts it.

    private func liveFixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: ext, subdirectory: "Fixtures/Intake")))
    }

    func testDecodesLiveCodexReviewOutput() throws {
        let out = try HarnessOutput.parse(.codex, stdout: try liveFixture("round-review-codex-live", "jsonl"))
        let review = try RoundPrompts.decode(ReviewOutput.self, out.structured)
        XCTAssertFalse(review.changes.isEmpty)
    }

    func testDecodesLiveClaudeReviewOutput() throws {
        let out = try HarnessOutput.parse(.claude, stdout: try liveFixture("round-review-claude-live", "json"))
        let review = try RoundPrompts.decode(ReviewOutput.self, out.structured)
        XCTAssertFalse(review.changes.isEmpty)
    }

    func testDecodesLiveCodexChangeSetOutput() throws {
        let out = try HarnessOutput.parse(.codex, stdout: try liveFixture("round-changeset-codex-live", "jsonl"))
        let cs = try RoundPrompts.decode(ChangeSetOutput.self, out.structured)
        XCTAssertEqual(cs.changeSet.ops.count, 0)
    }

    func testDecodesLiveClaudeChangeSetOutput() throws {
        let out = try HarnessOutput.parse(.claude, stdout: try liveFixture("round-changeset-claude-live", "json"))
        let cs = try RoundPrompts.decode(ChangeSetOutput.self, out.structured)
        XCTAssertEqual(cs.changeSet.ops.count, 0)
    }
}
