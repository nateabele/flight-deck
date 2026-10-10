import XCTest
import FleetKit
@testable import FlightDeck

/// grok's question card read as plain text: checkbox rows, the set position, the free-text
/// editor, the parked keyboard — synthetic screens in the shapes `.superpowers/grok-tui-facts-2.md`
/// §1 recorded live.
@MainActor
final class GrokQuestionCardTests: XCTestCase {
    func testACheckboxQuestionInASetIsReadWithItsBoxesAndPosition() throws {
        let card = try XCTUnwrap(GrokScreen.questionCard(inViewport: GrokScreenTests.screen("question-set-multi.synthetic")))
        XCTAssertEqual(card.title, "Pick toppings")
        XCTAssertEqual(card.position, .init(index: 2, count: 3))
        XCTAssertEqual(card.options.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(card.options.map(\.checked), [true, false, false])
        XCTAssertEqual(card.options[0].label, "Cheese  Melted on top", "the scrollbar thumb is not part of a label")
        XCTAssertEqual(card.freeText.checked, false)
        XCTAssertTrue(card.hasKeyboard)
        XCTAssertNil(card.editorText)
    }

    func testAnOpenEditorShowsItsTextAndTakesTheKeyboardFromTheRows() throws {
        let card = try XCTUnwrap(GrokScreen.questionCard(inViewport: GrokScreenTests.screen("question-editor.synthetic")))
        XCTAssertEqual(card.editorText, "Purple haze")
        XCTAssertFalse(card.hasKeyboard)
        XCTAssertEqual(card.options.map(\.checked), [nil, nil], "radio rows have no box")
    }

    /// One Escape parks the keyboard in the scrollback; the card stays drawn, but a digit no
    /// longer reaches it.
    func testAParkedCardDoesNotHaveTheKeyboard() throws {
        let card = try XCTUnwrap(GrokScreen.questionCard(inViewport: GrokScreenTests.screen("question-parked.synthetic")))
        XCTAssertFalse(card.hasKeyboard)
    }

    func testALoneQuestionHasNoPosition() throws {
        let card = try XCTUnwrap(GrokScreen.questionCard(inViewport: GrokScreenTests.screen("question.synthetic")))
        XCTAssertNil(card.position)
        XCTAssertEqual(card.title, "Red or blue?")
    }

    func testAPermissionCardIsNotAQuestionCard() throws {
        XCTAssertNil(GrokScreen.questionCard(inViewport: try GrokScreenTests.screen("permission-write.synthetic")))
        XCTAssertNil(GrokScreen.questionCard(inViewport: try GrokScreenTests.screen("permission-subagent.synthetic")))
    }

    /// A subagent's card is drawn in the parent's TUI with the scrollbar thumb on its rows; the
    /// plain "Yes" must still read as exactly "Yes".
    func testASubagentsPermissionCardStillOffersItsPlainYes() throws {
        XCTAssertEqual(GrokDialogDriver().allowKey(inViewport: try GrokScreenTests.screen("permission-subagent.synthetic")), "3")
    }
}

/// `GrokAnswerPlan.plan`: which keys answer which shape.
final class GrokAnswerPlanTests: XCTestCase {
    private let single = PromptQuestion(question: "Pick a color", options: [.init(label: "Red"), .init(label: "Blue")])
    private let multi = PromptQuestion(question: "Pick toppings",
                                       options: [.init(label: "Cheese"), .init(label: "Ham"), .init(label: "Olives")],
                                       multiSelect: true)

    private func step(_ q: Int, _ checked: Set<Int>?, _ editor: String?, _ keys: [KeyedAnswerStep.Key]) -> KeyedAnswerStep {
        KeyedAnswerStep(expect: .init(question: q, checked: checked, editor: editor), keys: keys)
    }

    func testASingleSelectQuestionIsItsOptionsKey() {
        XCTAssertEqual(GrokAnswerPlan.plan(for: [single], picks: [[.option(1)]]), [step(0, nil, nil, [.option(1)])])
    }

    /// Every box but the last is a Space toggle after clamping the unseen cursor to row 1; the last
    /// pick's own key commits — a digit on a checkbox question checks AND advances.
    func testACheckboxQuestionTogglesAllButTheLastPickThenCommitsWithIt() {
        XCTAssertEqual(GrokAnswerPlan.plan(for: [multi], picks: [[.option(2), .option(0)]]), [
            step(0, [], nil, [.up, .up, .up, .up]),
            step(0, [], nil, [.toggle]),
            step(0, [0], nil, [.option(2)]),
        ])
        XCTAssertEqual(GrokAnswerPlan.plan(for: [multi], picks: [[.option(1)]]), [step(0, [], nil, [.option(1)])],
                       "one box needs no cursor at all")
    }

    func testATypedAnswerIsTheFreeTextKeyAPasteAndOneReturn() {
        XCTAssertEqual(GrokAnswerPlan.plan(for: [single], picks: [[.typed("Purple")]]), [
            step(0, nil, nil, [.freeText]),
            step(0, nil, "", [.paste("Purple")]),
            step(0, nil, "Purple", [.commitText]),
        ])
        XCTAssertEqual(GrokAnswerPlan.plan(for: [multi], picks: [[.option(1), .typed("Pineapple")]]), [
            step(0, [], nil, [.up, .up, .up, .up]),
            step(0, [], nil, [.down, .toggle]),
            step(0, [1], nil, [.freeText]),
            step(0, [1], "", [.paste("Pineapple")]),
            step(0, [1], "Pineapple", [.commitText]),
        ])
    }

    func testASetIsEachQuestionInTurn() {
        let plan = GrokAnswerPlan.plan(for: [single, multi], picks: [[.option(0)], [.option(1)]])
        XCTAssertEqual(plan, [step(0, nil, nil, [.option(0)]), step(1, [], nil, [.option(1)])])
    }

    func testShapesThatCannotBeKeyedAreRefused() {
        XCTAssertNil(GrokAnswerPlan.plan(for: [single], picks: [[.option(0), .option(1)]]), "two picks on a radio")
        XCTAssertNil(GrokAnswerPlan.plan(for: [multi], picks: [[]]), "nothing chosen")
        XCTAssertNil(GrokAnswerPlan.plan(for: [single], picks: [[.typed("two\nlines")]]), "a newline is a keystroke")
        XCTAssertNil(GrokAnswerPlan.plan(for: [single], picks: [[.option(5)]]))
        XCTAssertNil(GrokAnswerPlan.plan(for: [single, multi], picks: [[.option(0)]]), "one answer per question")
        XCTAssertNil(GrokAnswerPlan.plan(for: [multi], picks: [[.option(1), .option(1)]]))
    }
}

/// The phone's question answers driven through `SessionStore` into a modelled grok card.
@MainActor
final class GrokAnswerDriveTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }
    private struct SilentReporter: AgentLaunchFailureReporting { func report(_ error: AgentLaunchError) {} }
    private struct Unavailable: Error {}

    private var base: URL!
    private var aborts: [AnswerAbort] = []

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("grok-drive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("proj"), withIntermediateDirectories: true)
        aborts = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func makeStore(_ sim: GrokQuestionCardSim) async throws -> (SessionStore, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.launchFailureReporter = SilentReporter()
        let home = base.appendingPathComponent("home")
        store.overrideAdapter(GrokAdapter(home: { home }), for: .grok, account: nil)
        store.injectorOverride = sim
        store.injectionSettle = { $0() }
        store.answerAbortSink = { [weak self] in self?.aborts.append($0) }
        guard case .success(let id) = await store.createSession(agent: .grok, in: base.appendingPathComponent("proj").path) else {
            XCTFail("a grok tab must be creatable")
            throw Unavailable()
        }
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        return (store, id)
    }

    private static let color = GrokQuestionCardSim.Question(text: "Pick a color", labels: ["Red", "Blue", "Green"], multi: false)
    private static let toppings = GrokQuestionCardSim.Question(text: "Pick toppings", labels: ["Cheese", "Ham", "Olives"], multi: true)
    private static let size = GrokQuestionCardSim.Question(text: "Pick a size", labels: ["Small", "Large"], multi: false)

    private static func prompt(_ questions: [GrokQuestionCardSim.Question]) -> OpenPrompt {
        .question(callID: "call-set", questions.map {
            PromptQuestion(question: $0.text, options: $0.labels.map { PromptQuestion.Option(label: $0) }, multiSelect: $0.multi)
        })
    }

    private func pick(_ index: Int, _ labels: [String]) -> AnswerSelection { AnswerSelection(index: index, label: labels[index]) }

    /// The probe's own set — a radio, three checkboxes with two ticked, a typed answer — lands as
    /// exactly those answers, and Return is pressed only into the open editor.
    func testAWholeSetIsAnswered() async throws {
        let sim = GrokQuestionCardSim([Self.color, Self.toppings, Self.size], startFocus: 2)
        let (store, id) = try await makeStore(sim)
        let answer = PromptAnswer.answers([
            [pick(1, Self.color.labels)],
            [pick(0, Self.toppings.labels), pick(2, Self.toppings.labels)],
            [AnswerSelection(index: 2, label: "", text: "Medium, please")],
        ])
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color, Self.toppings, Self.size]), with: answer, in: id, token: UUID()),
                       .dispatched)
        XCTAssertTrue(sim.submitted, "aborts: \(aborts.map(\.summary))")
        XCTAssertEqual(sim.answers, [.init(options: [1]), .init(options: [0, 2]), .init(options: [], typed: "Medium, please")])
        XCTAssertEqual(sim.events.filter { $0 == .ret }.count, 1, "the editor's commit is the only Return")
        XCTAssertEqual(sim.events.last, .ret)
    }

    func testALoneCheckboxQuestionTicksEveryPick() async throws {
        let sim = GrokQuestionCardSim([Self.toppings], startFocus: 3)
        let (store, id) = try await makeStore(sim)
        let labels = Self.toppings.labels
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.toppings]),
                                          with: .answers([[pick(1, labels), pick(2, labels), pick(0, labels)]]),
                                          in: id, token: UUID()), .dispatched)
        XCTAssertTrue(sim.submitted)
        XCTAssertEqual(sim.answers, [.init(options: [0, 1, 2])])
        XCTAssertFalse(sim.events.contains(.ret))
    }

    /// The phone's single-pick `.option` on a checkbox question used to be refused outright.
    func testAnOptionOnALoneCheckboxQuestionIsItsKey() async throws {
        let sim = GrokQuestionCardSim([Self.toppings])
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.toppings]), with: .option(index: 1, label: "Ham"),
                                          in: id, token: UUID()), .dispatched)
        XCTAssertEqual(sim.events, [.key("2")])
        XCTAssertEqual(sim.answers, [.init(options: [1])])
    }

    func testATypedAnswerToALoneQuestion() async throws {
        let sim = GrokQuestionCardSim([Self.size])
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.size]),
                                          with: .answers([[AnswerSelection(index: 2, label: "", text: "Huge")]]),
                                          in: id, token: UUID()), .dispatched)
        XCTAssertEqual(sim.events, [.key("z"), .paste("Huge"), .ret])
        XCTAssertEqual(sim.answers, [.init(options: [], typed: "Huge")])
    }

    /// A Space the TUI dropped leaves a box unticked; the drive sees it before the committing key
    /// and stops, so nothing is submitted with a box the reader chose missing.
    func testALostToggleStopsTheDriveBeforeAnythingCommits() async throws {
        let sim = GrokQuestionCardSim([Self.toppings])
        sim.dropSpaceNumber = 1
        let (store, id) = try await makeStore(sim)
        let labels = Self.toppings.labels
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.toppings]),
                                          with: .answers([[pick(0, labels), pick(2, labels)]]),
                                          in: id, token: UUID()), .dispatched)
        XCTAssertFalse(sim.submitted)
        XCTAssertFalse(sim.events.contains(.key("3")), "the committing key never went out")
        XCTAssertEqual(aborts.last?.check, .keyedScreenMismatch)
        XCTAssertNotNil(aborts.last?.viewport)
    }

    func testAParkedCardIsRefusedWithNothingSent() async throws {
        let sim = GrokQuestionCardSim([Self.color])
        sim.parked = true
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color]), with: .option(index: 0, label: "Red"),
                                          in: id, token: UUID()), .unreadableScreen)
        XCTAssertEqual(sim.events, [])
        XCTAssertEqual(aborts.last?.check, .keyedScreenMismatch)
    }

    /// The screen is on another question of the set than the transcript's first: refused, because a
    /// digit there would answer that question instead.
    func testASetWhoseScreenIsOnAnotherQuestionIsRefused() async throws {
        let sim = GrokQuestionCardSim([Self.color, Self.size])
        sim.sendCharacterKey("1")   // a person answered question 1 at the keyboard
        sim.clearEventsForTesting()
        let (store, id) = try await makeStore(sim)
        let answer = PromptAnswer.answers([[pick(0, Self.color.labels)], [pick(1, Self.size.labels)]])
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color, Self.size]), with: answer, in: id, token: UUID()),
                       .unreadableScreen)
        XCTAssertEqual(sim.events, [])
    }

    func testAPhoneLabelThisMacNeverSawIsRefused() async throws {
        let sim = GrokQuestionCardSim([Self.color, Self.size])
        let (store, id) = try await makeStore(sim)
        let answer = PromptAnswer.answers([[AnswerSelection(index: 0, label: "Crimson")], [pick(1, Self.size.labels)]])
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color, Self.size]), with: answer, in: id, token: UUID()),
                       .unreadableScreen)
        XCTAssertEqual(sim.events, [])
        XCTAssertEqual(aborts.last?.check, .setLabelMismatch)
    }
}

/// grok writes `multi_select`; the phone reads `multiSelect`.
final class GrokQuestionInputTests: XCTestCase {
    func testASnakeCaseMultiSelectReachesThePhoneAsACheckboxQuestion() throws {
        let line = #"{"timestamp":1,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"call-m","title":"ask_user_question","rawInput":{"questions":[{"question":"Pick toppings","options":[{"label":"Cheese","description":"Melted"},{"label":"Ham","description":"Thin"}],"multi_select":true},{"question":"Pick a size","options":[{"label":"Small","description":"S"}],"multi_select":false}]},"_meta":{"x.ai/tool":{"name":"ask_user_question","kind":"ask_user"}}}}}"#
        let item = try XCTUnwrap(GrokTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertEqual(PromptQuestion.all(toolInput: item.body.text).map(\.multiSelect), [true, false])
    }
}

/// A subagent's permission card: drawn in the parent's TUI, written only to the child's files.
@MainActor
final class GrokSubagentPromptTests: XCTestCase {
    private var root: URL!
    private let parentID = UUID()
    private let childID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-sub-\(UUID().uuidString)/sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    private var parentDir: URL { root.appendingPathComponent("%2Fproj/\(parentID.uuidString.lowercased())") }
    private var childDir: URL { root.appendingPathComponent("%2Fproj/\(childID.uuidString.lowercased())") }

    private func layOut(childStatus: String = "running", childHoldsCard: Bool = true) throws {
        try GrokSubagentFixture.layOut(parentDir: parentDir, childDir: childDir, parentID: parentID, childID: childID,
                                       childStatus: childStatus, childHoldsCard: childHoldsCard)
    }

    func testTheParentReadsWaitingWhileItsChildHoldsACard() throws {
        try layOut()
        let runtime = GrokRuntime()
        var events: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: parentID, transcriptURL: parentDir.appendingPathComponent("updates.jsonl")),
                           for: UUID()) { events.append($0) }
        runtime.drainForTesting()
        XCTAssertEqual(events.last(where: { if case .activity = $0 { return true } else { return false } }), .activity(.waiting))
    }

    func testAFinishedChildHoldsNothing() throws {
        try layOut(childStatus: "completed")
        let runtime = GrokRuntime()
        var events: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: parentID, transcriptURL: parentDir.appendingPathComponent("updates.jsonl")),
                           for: UUID()) { events.append($0) }
        runtime.drainForTesting()
        let last = events.last(where: { if case .activity = $0 { return true } else { return false } })
        XCTAssertNotNil(last)
        XCTAssertNotEqual(last, .activity(.waiting), "a completed child's leftover request is not a card")
    }

    /// The parent's own open call is `spawn_subagent`; the card on screen is the child's write.
    func testTheOpenPromptIsTheChildsCallNotTheSpawn() throws {
        try layOut()
        let transcript = parentDir.appendingPathComponent("updates.jsonl")
        let open = GrokOpenPromptReader().openPrompt(
            inTranscriptAt: transcript, tail: GrokSubagents.tailLines(of: transcript), activity: .waiting)
        XCTAssertEqual(open, .permission(callID: "call-write", tool: "write", summary: "/proj/b.txt"))
    }

    func testWithNoChildCardTheParentsOwnCallStands() throws {
        try layOut(childHoldsCard: false)
        let transcript = parentDir.appendingPathComponent("updates.jsonl")
        let open = GrokOpenPromptReader().openPrompt(
            inTranscriptAt: transcript, tail: GrokSubagents.tailLines(of: transcript), activity: .waiting)
        XCTAssertEqual(open, .permission(callID: "call-spawn", tool: "spawn_subagent", summary: open.flatMap {
            if case .permission(_, _, let summary) = $0 { return summary } else { return nil } }))
    }

    /// Two children holding cards: which one is on screen cannot be read, so nothing is offered.
    func testTwoChildCardsAreRefused() {
        var reader = GrokOpenPromptReader()
        reader.childrenHoldingPermission = { _ in [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")] }
        XCTAssertNil(reader.openPrompt(inTranscriptAt: URL(fileURLWithPath: "/x/updates.jsonl"), tail: [], activity: .waiting))
    }
}

/// A parent grok session sitting in a foreground `spawn_subagent` whose child raised a write card
/// (facts-2 §4), synthetic.
enum GrokSubagentFixture {
    static func record(_ session: UUID, _ update: String) -> String {
        #"{"timestamp":1,"method":"session/update","params":{"sessionId":"\#(session.uuidString.lowercased())","update":\#(update)}}"#
    }

    static func layOut(parentDir: URL, childDir: URL, parentID: UUID, childID: UUID,
                       childStatus: String = "running", childHoldsCard: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: childDir, withIntermediateDirectories: true)
        let meta = parentDir.appendingPathComponent("subagents/\(childID.uuidString.lowercased())")
        try fm.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data(#"{"child_session_id":"\#(childID.uuidString.lowercased())","status":"\#(childStatus)"}"#.utf8)
            .write(to: meta.appendingPathComponent("meta.json"))
        let parentUpdates = [
            record(parentID, #"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"make b.txt"}}"#),
            record(parentID, #"{"sessionUpdate":"tool_call","toolCallId":"call-spawn","title":"spawn_subagent","rawInput":{"description":"Make b.txt","background":false},"_meta":{"x.ai/tool":{"name":"spawn_subagent","kind":"task"}}}"#),
        ]
        try Data((parentUpdates.joined(separator: "\n") + "\n").utf8).write(to: parentDir.appendingPathComponent("updates.jsonl"))
        let parentEvents = [
            #"{"type":"turn_started"}"#,
            #"{"type":"permission_requested","tool_name":"spawn_subagent"}"#,
            #"{"type":"permission_resolved","tool_name":"spawn_subagent","decision":"allow","wait_ms":900}"#,
            #"{"type":"phase_changed","phase":"tool_execution"}"#,
        ]
        try Data((parentEvents.joined(separator: "\n") + "\n").utf8).write(to: parentDir.appendingPathComponent("events.jsonl"))
        let childUpdates = [
            record(childID, #"{"sessionUpdate":"tool_call","toolCallId":"call-write","title":"write","rawInput":{"file_path":"/proj/b.txt","content":"hi"},"_meta":{"x.ai/tool":{"name":"write","kind":"write"}}}"#),
        ]
        try Data((childUpdates.joined(separator: "\n") + "\n").utf8).write(to: childDir.appendingPathComponent("updates.jsonl"))
        var childEvents = [#"{"type":"turn_started"}"#, #"{"type":"permission_requested","tool_name":"write"}"#]
        if !childHoldsCard { childEvents.append(#"{"type":"permission_resolved","tool_name":"write","decision":"allow","wait_ms":5}"#) }
        try Data((childEvents.joined(separator: "\n") + "\n").utf8).write(to: childDir.appendingPathComponent("events.jsonl"))
    }
}

/// The child's card end to end through `PromptService`: attributed to the child so the phone
/// reads the child's file, answered with the child as the agent and no hook log to vouch.
@MainActor
final class GrokSubagentAnswerTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }
    private struct SilentReporter: AgentLaunchFailureReporting { func report(_ error: AgentLaunchError) {} }
    private struct Unavailable: Error {}

    private var base: URL!
    private let childID = UUID()

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("grok-subans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("proj"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func make() async throws -> (PromptService, SpyInjector, UUID, URL) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.launchFailureReporter = SilentReporter()
        let home = base.appendingPathComponent("home")
        store.overrideAdapter(GrokAdapter(home: { home }), for: .grok, account: nil)
        let spy = SpyInjector()
        spy.viewportOverride = try GrokScreenTests.screen("permission-subagent.synthetic")
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        store.answerAbortSink = { _ in }
        guard case .success(let id) = await store.createSession(agent: .grok, in: base.appendingPathComponent("proj").path),
              case .file(_, let transcript) = store.timelineSource(of: id),
              let session = store.repos.flatMap(\.sessions).first(where: { $0.id == id })
        else {
            XCTFail("a grok tab with a transcript")
            throw Unavailable()
        }
        let parentDir = transcript.deletingLastPathComponent()
        try GrokSubagentFixture.layOut(
            parentDir: parentDir,
            childDir: parentDir.deletingLastPathComponent().appendingPathComponent(childID.uuidString.lowercased()),
            parentID: session.pinnedConversationID, childID: childID)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        spy.events.removeAll()
        let service = PromptService(store: store)
        service.lifecycleSink = { _ in }
        return (service, spy, id, transcript)
    }

    func testTheCardIsTheChildsAndAttributedToIt() async throws {
        let (service, _, id, _) = try await make()
        guard case .success(let open) = service.pushedOpenPrompt(inSession: id) else { return XCTFail("no open prompt") }
        XCTAssertEqual(open.callID, "call-write")
        XCTAssertEqual(service.openPromptAgent(inSession: id), childID.uuidString.lowercased())
    }

    func testAllowNamedForTheChildPressesTheScreensYes() async throws {
        let (service, spy, id, _) = try await make()
        let result = service.answer(session: id, agent: childID.uuidString.lowercased(), call: "call-write",
                                    answer: .allow, token: UUID())
        if case .failure(let code) = result { XCTFail("refused: \(code.code)") }
        XCTAssertEqual(spy.events, [.key("3")])
    }

    func testTheSpawnCallIsNoLongerAnsweredAsIfItWereTheCard() async throws {
        let (service, spy, id, _) = try await make()
        let result = service.answer(session: id, agent: nil, call: "call-spawn", answer: .allow, token: UUID())
        guard case .failure(let code) = result else { return XCTFail("the spawn call is not the card on screen") }
        XCTAssertEqual(code.code, "prompt_changed")
        XCTAssertEqual(spy.events, [])
    }

    /// The child answers one card and raises the next while the parent's transcript does not move
    /// and the tab never leaves `waiting`: the scheduled probe must not serve the first card from
    /// its cache.
    func testAChildsNextCardIsNotServedFromTheCache() async throws {
        let (service, _, id, transcript) = try await make()
        guard case .success(let first)? = service.polledOpenPrompt(inSession: id) else { return XCTFail("no first card") }
        XCTAssertEqual(first.callID, "call-write")
        let child = transcript.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(childID.uuidString.lowercased())
        let more = [
            GrokSubagentFixture.record(childID, #"{"sessionUpdate":"tool_call_update","toolCallId":"call-write","status":"completed","content":[]}"#),
            GrokSubagentFixture.record(childID, #"{"sessionUpdate":"tool_call","toolCallId":"call-write-2","title":"write","rawInput":{"file_path":"/proj/c.txt"},"_meta":{"x.ai/tool":{"name":"write","kind":"write"}}}"#),
        ]
        let updates = try FileHandle(forWritingTo: child.appendingPathComponent("updates.jsonl"))
        try updates.seekToEnd()
        try updates.write(contentsOf: Data((more.joined(separator: "\n") + "\n").utf8))
        try updates.close()
        let events = try FileHandle(forWritingTo: child.appendingPathComponent("events.jsonl"))
        try events.seekToEnd()
        try events.write(contentsOf: Data((#"{"type":"permission_resolved","tool_name":"write","decision":"allow","wait_ms":4}"# + "\n"
            + #"{"type":"permission_requested","tool_name":"write"}"# + "\n").utf8))
        try events.close()
        guard case .success(let next)? = service.polledOpenPrompt(inSession: id) else { return XCTFail("no next card") }
        XCTAssertEqual(next.callID, "call-write-2")
    }

    /// The phone reads the child's own file for the card, and only a child this session spawned.
    func testTheChildsTranscriptIsReadableOnlyForAChildOfThisSession() async throws {
        let (_, _, _, transcript) = try await make()
        let reader = GrokOpenPromptReader()
        let child = childID.uuidString.lowercased()
        XCTAssertEqual(reader.subagentTranscript(for: transcript, agent: child)?.lastPathComponent, "updates.jsonl")
        XCTAssertEqual(reader.subagentTranscript(for: transcript, agent: child)?.deletingLastPathComponent().lastPathComponent, child)
        XCTAssertNil(reader.subagentTranscript(for: transcript, agent: UUID().uuidString.lowercased()), "not a child")
        XCTAssertNil(reader.subagentTranscript(for: transcript, agent: "../../etc"), "never a path")
        XCTAssertNil(reader.subagentTranscript(for: transcript, agent: transcript.deletingLastPathComponent().lastPathComponent),
                     "the session itself is not its own child")
    }
}
