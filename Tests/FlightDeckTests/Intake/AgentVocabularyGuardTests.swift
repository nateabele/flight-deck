import XCTest
import IntakeKit

/// No agent ever reads the project's old word for a task: builds every prompt Flight Deck can send
/// and every schema it hands an agent, then fails on the word in any case. Each prompt must also
/// carry `AgentVocabulary.rule`, so a prompt added later can't leave it out.
final class AgentVocabularyGuardTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_798_920_000)
    private let old = "bead"

    private var kinds: [TaskKind] {
        [TaskKind(id: "tests", name: "Tests", description: "Write tests", dimensions: ["test-authoring": 0.8],
                  origin: .seed, createdAt: observedAt)]
    }

    private func context(agents: Bool) -> RoundContext {
        RoundContext(intent: "Ship it", qa: [TriageExchange(questions: ["Which?"], answers: ["All"])],
                     graphFile: "/i/graph.json", agentsFile: agents ? "/p/AGENTS.md" : nil,
                     readmeFile: agents ? "/p/README.md" : nil,
                     notes: [PlanNote(kind: .mustChange, note: "n",
                                      anchor: NoteAnchor(checkpoint: 1, quote: "q", section: "S"))],
                     humanEdits: "-a\n+b", observedAt: observedAt, kinds: kinds)
    }

    private var errors: [ValidationError] {
        [.unknownBead("fd-1"), .undefinedTempId("t1"), .duplicateTempId("t1"), .selfEdge("fd-1"), .cycle,
         .missingDelivery("fd-1"), .preconditionMismatch("fd-1")]
    }

    private func allPrompts() -> [(String, String)] {
        let analytics = [nil, ShadowAnalytics(insights: "/a", plan: "/b", priority: "/c")]
        var out: [(String, String)] = []
        for withFiles in [true, false] {
            let c = context(agents: withFiles)
            for kindsOn in [true, false] {
                var c = c; if !kindsOn { c.kinds = [] }
                out.append(("triage.initial", Triage.initialPrompt(
                    intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                    agentsFile: withFiles ? "/p/AGENTS.md" : nil, readmeFile: withFiles ? "/p/README.md" : nil,
                    observedAt: observedAt, kinds: c.kinds)))
                for persona in [DrafterPersona.general, .arbiter, .realist, .coverage, .stressTest] {
                    out.append(("draft.\(persona)", RoundPrompts.draft(c, persona: persona)))
                }
                out.append(("synthesis", RoundPrompts.synthesis(c, ownDraft: "/d1", otherDrafts: ["/d2"])))
                out.append(("review", RoundPrompts.review(c, planFile: "/plan.md", round: 1)))
                out.append(("encode", RoundPrompts.encode(c, planFile: "/plan.md")))
                for a in analytics {
                    out.append(("polish", RoundPrompts.polish(c, planFile: "/plan.md", changeSetFile: "/cs.json", round: 2, analytics: a)))
                    out.append(("freshEyes", RoundPrompts.freshEyes(c, planFile: "/plan.md", changeSetFile: "/cs.json", analytics: a)))
                    out.append(("dedup", RoundPrompts.dedup(c, changeSetFile: "/cs.json", analytics: a)))
                }
            }
        }
        for clustered in [true, false] {
            out.append(("integrate", RoundPrompts.integrate(planFile: "/plan.md", changesFile: "/ch.json",
                                                            humanEdits: "-a\n+b", clustered: clustered)))
        }
        out.append(("triage.answers", Triage.answersPrompt(questions: ["Q"], answers: ["A"])))
        out.append(("triage.correction", Triage.correctionPrompt(errors: errors, observedAt: observedAt)))
        out.append(("triage.encodeNow", Triage.encodeNowPrompt(observedAt: observedAt)))
        out.append(("changeSetCorrection", RoundPrompts.changeSetCorrection(errors: errors, observedAt: observedAt)))
        out.append(("repair", SchemaRepair.prompt(firstError: "missing key")))
        out.append(("repair.answerless", SchemaRepair.answerlessPrompt))
        return out
    }

    func testNoPromptSaysTheOldWordAndEveryOneCarriesTheRule() {
        let prompts = allPrompts()
        XCTAssertGreaterThan(prompts.count, 40)
        for (name, text) in prompts {
            XCTAssertFalse(text.lowercased().contains(old), "\(name) mentions the old word:\n\(text)")
            XCTAssertTrue(text.contains(AgentVocabulary.rule), "\(name) is missing AgentVocabulary.rule")
        }
        XCTAssertFalse(AgentVocabulary.rule.lowercased().contains(old))
    }

    func testNoSchemaSaysTheOldWord() {
        let schemas: [String: String] = [
            "triage": Triage.schemaJSON, "changeSetFragment": Triage.changeSetSchemaFragment,
            "triage.gemini": GeminiSchema.compatible(Triage.schemaJSON),
            "draft": RoundSchemas.draft, "review": RoundSchemas.review, "integrate": RoundSchemas.integrate,
            "integrateClustered": RoundSchemas.integrateClustered, "changeSet": RoundSchemas.changeSet,
            "changeSet.gemini": GeminiSchema.compatible(RoundSchemas.changeSet),
        ]
        for (name, schema) in schemas { XCTAssertFalse(schema.lowercased().contains(old), "\(name) schema: \(schema)") }
        XCTAssertTrue(Triage.schemaJSON.contains("\"singleTask\""))
        XCTAssertTrue(Triage.schemaJSON.contains("\"createTask\"") && Triage.schemaJSON.contains("\"editTask\""))
    }

    func testValidatorFeedbackAndDeliveryTextToAgentsSayTask() {
        for e in errors { XCTAssertFalse(e.message.lowercased().contains(old), e.message) }
        for rating in DeliveryRating.allCases {
            XCTAssertFalse(DeliveryPlanner.subject(for: rating, bead: "fd-1").lowercased().contains(old))
            for outcome in [DeliveryOutcome.notAttempted, .succeeded, .failed] {
                let body = DeliveryPlanner.mailBody(for: rating, bead: "fd-1", reason: "r", outcome: outcome)
                XCTAssertFalse(body.lowercased().contains(old), body)
            }
        }
    }

    func testGraphSnapshotAgentsReadIsKeyedByTasksAndOldFileStillDecodes() throws {
        let g = GraphSnapshot(beads: ["fd-1": BeadSnapshot(id: "fd-1", title: "T", status: "open")])
        let text = String(decoding: try IntakeJSON.encoder.encode(g), as: UTF8.self)
        XCTAssertTrue(text.contains("\"tasks\""), text)
        XCTAssertFalse(text.lowercased().contains(old), text)
        XCTAssertEqual(try IntakeJSON.decoder.decode(GraphSnapshot.self, from: Data(text.utf8)), g)
        let legacy = #"{"beads":{"fd-1":{"id":"fd-1","title":"T","status":"open","labels":[]}},"edges":[]}"#
        XCTAssertEqual(try IntakeJSON.decoder.decode(GraphSnapshot.self, from: Data(legacy.utf8)), g)
    }

    func testChangeSetWritesNewOpNamesAndReadsBoth() throws {
        let cs = ChangeSet(graphObservedAt: observedAt, ops: [
            .createBead(NewBead(tempId: "n1", title: "T", description: "d")),
            .editBead(id: "b1", set: FieldSet(title: "x"), pre: Precondition(status: "open", assignee: nil), delivery: nil)])
        let text = String(decoding: try cs.encoded(), as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains(old), text)
        XCTAssertEqual(try ChangeSet.decode(Data(text.utf8)), cs)
        let legacy = text.replacingOccurrences(of: "createTask", with: "createBead")
            .replacingOccurrences(of: "editTask", with: "editBead")
        XCTAssertTrue(legacy.contains("createBead"))
        XCTAssertEqual(try ChangeSet.decode(Data(legacy.utf8)), cs)
    }

    func testPresetDecodesBothSpellingsAndStoresTheOld() throws {
        for raw in ["singleTask", "bead"] {
            XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: Data("\"\(raw)\"".utf8)), .bead)
        }
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(Preset.bead), as: UTF8.self), "\"bead\"")
        XCTAssertThrowsError(try JSONDecoder().decode(Preset.self, from: Data("\"nope\"".utf8)))
    }
}
