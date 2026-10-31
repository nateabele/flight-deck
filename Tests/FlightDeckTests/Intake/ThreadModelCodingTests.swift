import XCTest
import IntakeKit

/// The ask-thread shapes (P1 Task 0): what ThreadRunner writes under `threads/`, what the agent
/// answers each turn, and what the app and phone append to `threads/commands.jsonl`. Every
/// stream codes against these, so each one must survive a round trip byte-for-meaning, and
/// the agent's answer must decode from exactly the shape `ThreadActions.schemaJSON` asks for.
final class ThreadModelCodingTests: XCTestCase {
    private let thread = ThreadID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    private let anchor = NoteAnchor(checkpoint: 4, quote: "the job stays Unassigned", section: "## Scope",
                                    prefix: "When offline, ", suffix: " until sync.")

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try IntakeJSON.encoder.encode(value)
        XCTAssertEqual(try IntakeJSON.decoder.decode(T.self, from: data), value, file: file, line: line)
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: IntakeJSON.encoder.encode(value)) as? [String: Any])
    }

    // MARK: - Model

    /// A bare UUID string, so a thread id reads the same in a file name, a JSON line and a wire
    /// field — never `{"raw": …}`.
    func testThreadIDEncodesAsABareUUID() throws {
        let data = try JSONEncoder().encode([thread])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["11111111-2222-3333-4444-555555555555"]"#)
        XCTAssertEqual(try JSONDecoder().decode([ThreadID].self, from: data), [thread])
    }

    func testStatusAndDiffStateRawValuesAreTheStorageFormat() {
        XCTAssertEqual([ThreadStatus.open, .answering, .needsYou, .stale, .resolved].map(\.rawValue),
                       ["open", "answering", "needsYou", "stale", "resolved"])
        XCTAssertEqual([DiffState.pending, .accepted, .rejected, .stale].map(\.rawValue),
                       ["pending", "accepted", "rejected", "stale"])
    }

    func testRecordRoundTripsWithAndWithoutASession() throws {
        let record = ThreadRecord(id: thread, title: "Why Unassigned?", anchor: ThreadAnchor(note: anchor),
                                  status: .open, agent: .codex, model: "gpt-5.5", effort: "high",
                                  autoAccept: false, sessionID: nil, followsCheckpoint: 4,
                                  createdAt: Date(timeIntervalSince1970: 1_800_000_000.123_456))
        try roundTrip(record)
        var resumed = record
        resumed.sessionID = "sess-1"
        resumed.status = .needsYou
        try roundTrip(resumed)
        XCTAssertNil(try object(record)["sessionID"], "nil is absent, never null")
    }

    /// A nil note anchor is a thread about the whole plan; the visual fields stay absent until P2a.
    func testWholePlanAnchorEncodesAsAnEmptyObject() throws {
        XCTAssertEqual(ThreadAnchor.wholePlan, ThreadAnchor(note: nil, visualID: nil, elementID: nil))
        XCTAssertTrue(try object(ThreadAnchor.wholePlan).isEmpty)
        try roundTrip(ThreadAnchor(note: anchor, visualID: "v1", elementID: "e2"))
    }

    func testTurnRoundTripsWithEveryActionKind() throws {
        let question = StructuredQuestion(id: "q1", text: "Keep the 24h timer?", kind: .single,
                                          options: [.init(id: "a", label: "Yes"), .init(id: "b", label: "No")],
                                          recommended: ["a"], allowOther: true)
        let note = PlanNote(kind: .mustChange, note: "Say who assigns it", anchor: anchor, source: .thread(thread))
        let turn = ThreadTurn(
            seq: 2, messageID: "m-2", you: "Why 24 hours?", answers: [StructuredAnswer(questionID: "q0", selected: ["x"])],
            reply: "Because [cite:d1] said so.", decision: "Keep 24h.",
            actions: [.proposeDiff(ProposedThreadDiff(checkpoint: 4, quote: "the job stays Unassigned",
                                                      prefix: "When offline, ", suffix: " until sync.",
                                                      replacement: "the job stays with its dispatcher")),
                      .addNote(note), .askQuestion(question)],
            errors: ["ambiguous: quote more context"], checkpoint: 4,
            startedAt: Date(timeIntervalSince1970: 1_800_000_001), endedAt: Date(timeIntervalSince1970: 1_800_000_009))
        try roundTrip(turn)
        var running = turn
        running.reply = nil
        running.decision = nil
        running.endedAt = nil
        running.actions = []
        try roundTrip(running)
    }

    /// A turn written by a later build (P2a's `makeVisual`) still loads here: the action this
    /// build can't show is dropped, not the whole turn — or a thread would vanish from the panel.
    func testATurnWithAnActionFromALaterBuildKeepsTheRest() throws {
        let json = """
        {"seq":1,"messageID":"m","reply":"r","actions":[
          {"op":"makeVisual","kind":"diagram.sequence","brief":"b","anchorSection":"s3"},
          {"op":"askQuestion","question":{"id":"q1","text":"T?","kind":"text","options":[],"recommended":[],"allowOther":false}}],
         "errors":[],"checkpoint":3,"startedAt":"2026-10-31T10:00:00.000Z"}
        """
        let turn = try IntakeJSON.decoder.decode(ThreadTurn.self, from: Data(json.utf8))
        XCTAssertEqual(turn.actions, [.askQuestion(.text(id: "q1", "T?"))])
    }

    func testDiffRoundTripsInEveryState() throws {
        for state in [DiffState.pending, .accepted, .rejected, .stale] {
            try roundTrip(ThreadDiff(id: UUID(), thread: thread, checkpoint: 4, anchor: anchor,
                                     old: "the job stays Unassigned", new: "the job stays with its dispatcher", state: state))
        }
    }

    // MARK: - The agent's answer

    /// Exactly what a strict-mode agent sends: every key present, unused ones null.
    func testAnswerDecodesTheSchemaShapeWithNulls() throws {
        let json = """
        {"reply":"See [cite:v2].","decision":null,"actions":[
          {"op":"proposeDiff","checkpoint":4,"quote":"q","prefix":"p","suffix":"s","replacement":"r",
           "kind":null,"anchor":null,"note":null,"question":null},
          {"op":"addNote","checkpoint":null,"quote":null,"prefix":null,"suffix":null,"replacement":null,
           "kind":"mustChange","anchor":{"checkpoint":4,"quote":"q","section":null,"prefix":"p","suffix":"s"},
           "note":"Name the owner","question":null},
          {"op":"addNote","checkpoint":null,"quote":null,"prefix":null,"suffix":null,"replacement":null,
           "kind":"comment","anchor":null,"note":"About the whole plan","question":null},
          {"op":"askQuestion","checkpoint":null,"quote":null,"prefix":null,"suffix":null,"replacement":null,
           "kind":null,"anchor":null,"note":null,
           "question":{"id":"q1","text":"Which?","kind":"multi","options":[{"id":"a","label":"A","detail":null},{"id":"b","label":"B","detail":"bee"}],
                       "recommended":["a"],"allowOther":true}}]}
        """
        let answer = try ThreadActions.decode(Data(json.utf8))
        XCTAssertEqual(answer.reply, "See [cite:v2].")
        XCTAssertEqual(answer.decision, "", "a null decision is no decision")
        XCTAssertEqual(answer.actions.count, 4)
        XCTAssertEqual(answer.actions[0], .proposeDiff(ProposedThreadDiff(checkpoint: 4, quote: "q", prefix: "p", suffix: "s",
                                                                          replacement: "r")))
        guard case .addNote(let anchored) = answer.actions[1], case .addNote(let whole) = answer.actions[2] else {
            return XCTFail("expected two notes, got \(answer.actions)")
        }
        XCTAssertEqual(anchored.kind, .mustChange)
        XCTAssertEqual(anchored.note, "Name the owner")
        XCTAssertEqual(anchored.anchor, NoteAnchor(checkpoint: 4, quote: "q", section: nil, prefix: "p", suffix: "s"))
        XCTAssertNil(whole.anchor)
        XCTAssertNotEqual(anchored.id, whole.id, "each note the agent adds is its own note")
        XCTAssertEqual(answer.actions[3], .askQuestion(StructuredQuestion(
            id: "q1", text: "Which?", kind: .multi,
            options: [.init(id: "a", label: "A"), .init(id: "b", label: "B", detail: "bee")],
            recommended: ["a"], allowOther: true)))
    }

    func testAnswerWithNoActionsDecodes() throws {
        let answer = try ThreadActions.decode(Data(#"{"reply":"Nothing to change.","decision":"","actions":null}"#.utf8))
        XCTAssertEqual(answer, ThreadAnswer(reply: "Nothing to change.", decision: "", actions: []))
    }

    /// Off-schema output is refused with a reason ThreadRunner can feed back to the agent,
    /// never half-applied.
    func testAnswerRefusesAnUnknownOpAndAMissingField() {
        for json in [#"{"reply":"r","decision":"","actions":[{"op":"makeVisual"}]}"#,
                     #"{"reply":"r","decision":"","actions":[{"op":"proposeDiff","checkpoint":1,"quote":"q"}]}"#,
                     #"{"reply":"r","decision":"","actions":[{"op":"addNote","kind":"shout","note":"n"}]}"#,
                     #"{"decision":"","actions":[]}"#] {
            XCTAssertThrowsError(try ThreadActions.decode(Data(json.utf8)), json) { error in
                XCTAssertTrue(error is ThreadActions.Malformed, "\(json): \(error)")
            }
        }
    }

    /// Both CLIs reject a non-strict schema: every object must close `additionalProperties`
    /// and list every property it declares in `required`.
    func testSchemaIsStrictJSON() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ThreadActions.schemaJSON.utf8)) as? [String: Any])
        func check(_ node: Any, _ path: String) {
            if let list = node as? [Any] { list.enumerated().forEach { check($1, "\(path)[\($0)]") }; return }
            guard let obj = node as? [String: Any] else { return }
            if let props = obj["properties"] as? [String: Any] {
                XCTAssertEqual(obj["additionalProperties"] as? Bool, false, "\(path) must close additionalProperties")
                XCTAssertEqual(Set(obj["required"] as? [String] ?? []), Set(props.keys), "\(path) must require every property")
            }
            obj.forEach { check($1, "\(path).\($0)") }
        }
        check(schema, "$")
        let ops = (((schema["properties"] as? [String: Any])?["actions"] as? [String: Any])?["items"] as? [String: Any])
            .flatMap { ($0["properties"] as? [String: Any])?["op"] as? [String: Any] }?["enum"] as? [String]
        XCTAssertEqual(ops, ["proposeDiff", "addNote", "askQuestion"])
    }

    // MARK: - threads/commands.jsonl

    func testEveryThreadCommandRoundTripsFlatWithItsKind() throws {
        let diff = UUID()
        let cases: [(ThreadCommand, String)] = [
            (.open(thread, ThreadAnchor(note: anchor), title: "Why?", agent: .claude, model: "opus", effort: "high"), "open"),
            (.message(thread, text: "Why 24h?", messageID: "m1", source: nil, elementID: nil, subjectRevision: nil), "message"),
            (.message(thread, text: "This node", messageID: "m2", source: "canvas", elementID: "e1", subjectRevision: "r3"), "message"),
            (.answer(thread, [StructuredAnswer(questionID: "q1", selected: ["a"], other: "and b")], messageID: "m3"), "answer"),
            (.setAutoAccept(thread, true), "setAutoAccept"),
            (.setAgent(thread, .gemini, model: "gemini-3", effort: "medium"), "setAgent"),
            (.resolve(thread), "resolve"),
            (.reopen(thread), "reopen"),
            (.repropose(thread, diff: diff), "repropose"),
            (.decideDiff(thread, diff: diff, accept: false), "decideDiff"),
        ]
        for (command, kind) in cases {
            try roundTrip(command)
            let obj = try object(command)
            XCTAssertEqual(obj["kind"] as? String, kind)
            XCTAssertEqual(obj["thread"] as? String, thread.raw.uuidString)
        }
        let plain = try object(ThreadCommand.message(thread, text: "t", messageID: "m", source: nil, elementID: nil,
                                                     subjectRevision: nil))
        XCTAssertEqual(Set(plain.keys), ["kind", "thread", "text", "messageID"], "the canvas fields stay absent when nil")
        try roundTrip(ThreadCommandEnvelope(seq: 7, command: .resolve(thread)))
    }

    /// A kind a later build adds must fail this build's decode, so the line is dropped like an
    /// unknown tape command rather than misread as another kind.
    func testAnUnknownThreadCommandKindThrows() {
        let json = #"{"kind":"makeVisual","thread":"11111111-2222-3333-4444-555555555555"}"#
        XCTAssertThrowsError(try IntakeJSON.decoder.decode(ThreadCommand.self, from: Data(json.utf8)))
    }
}
