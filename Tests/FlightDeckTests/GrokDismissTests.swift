import XCTest
import FleetKit
@testable import FlightDeck

/// Denying a grok QUESTION is Shift+x — "Dismiss the question (the agent continues without an
/// answer)" — and not Ctrl+C, which cancels the whole turn. Probed live on grok 1.0.30
/// (`.superpowers/grok-tui-facts-2.md` §6): the tool returns "User declined to answer the
/// questions…" and the model goes on.
@MainActor
final class GrokDismissStepTests: XCTestCase {
    private let driver = GrokDialogDriver()

    private static let lone = [PromptQuestion(header: nil, question: "Red or blue?",
                                              options: [.init(label: "Red"), .init(label: "Blue")])]
    private static let set = [
        PromptQuestion(header: nil, question: "Pick a color", options: [.init(label: "Red"), .init(label: "Blue")]),
        PromptQuestion(header: nil, question: "Pick toppings", options: [.init(label: "Cheese")], multiSelect: true),
        PromptQuestion(header: nil, question: "Pick a size", options: [.init(label: "Small")]),
    ]

    func testACardHoldingTheKeyboardIsDismissedWithShiftX() throws {
        let screen = try GrokScreenTests.screen("question.synthetic")
        XCTAssertEqual(driver.dismissStep(for: Self.lone, inViewport: screen), .press([.character("X")]))
    }

    /// Parked in the scrollback, the bar no longer offers `Shift+x:dismiss`; Tab gives the card
    /// its keyboard back, and the dismiss waits for the bar to say so.
    func testAParkedCardIsGivenTheKeyboardBackFirst() throws {
        let screen = try GrokScreenTests.screen("question-parked.synthetic")
        XCTAssertEqual(driver.dismissStep(for: Self.set, inViewport: screen), .refocus([.tab]))
    }

    /// In an open editor an `X` is a letter of the answer, not a dismiss.
    func testAnOpenEditorBlocksTheDismiss() throws {
        let screen = try GrokScreenTests.screen("question-editor.synthetic")
        XCTAssertEqual(driver.dismissStep(for: Self.set, inViewport: screen), .blocked)
    }

    /// Another question's card, a permission card, the composer: not the card being dismissed.
    func testAnyOtherScreenIsAbsent() throws {
        XCTAssertEqual(driver.dismissStep(for: Self.set, inViewport: try GrokScreenTests.screen("question.synthetic")),
                       .absent)
        XCTAssertEqual(driver.dismissStep(for: Self.lone, inViewport: try GrokScreenTests.screen("permission-write.synthetic")),
                       .absent)
        XCTAssertEqual(driver.dismissStep(for: Self.lone, inViewport: try GrokScreenTests.screen("tui-idle.synthetic")),
                       .absent)
    }

    /// The abort path has no transcript call to compare against: any question card will do.
    func testWithNoQuestionsAnyQuestionCardIsDismissable() throws {
        XCTAssertEqual(driver.dismissStep(for: nil, inViewport: try GrokScreenTests.screen("question.synthetic")),
                       .press([.character("X")]))
        XCTAssertEqual(driver.dismissStep(for: nil, inViewport: try GrokScreenTests.screen("permission-write.synthetic")),
                       .absent)
    }
}

/// The dismiss through `SessionStore`, into `GrokQuestionCardSim`.
@MainActor
final class GrokDismissDriveTests: XCTestCase {
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
        base = FileManager.default.temporaryDirectory.appendingPathComponent("grok-dismiss-\(UUID().uuidString)")
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

    private static let color = GrokQuestionCardSim.Question(text: "Pick a color", labels: ["Red", "Blue"], multi: false)
    private static let size = GrokQuestionCardSim.Question(text: "Pick a size", labels: ["Small", "Large"], multi: false)

    private static func prompt(_ questions: [GrokQuestionCardSim.Question]) -> OpenPrompt {
        .question(callID: "call-q", questions.map {
            PromptQuestion(question: $0.text, options: $0.labels.map { PromptQuestion.Option(label: $0) }, multiSelect: $0.multi)
        })
    }

    func testDenyOnAQuestionIsShiftXAndNeverCancelsTheTurn() async throws {
        let sim = GrokQuestionCardSim([Self.color])
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color]), with: .deny, in: id, token: UUID()), .dispatched)
        XCTAssertEqual(sim.events, [.key("X")])
        XCTAssertTrue(sim.dismissed)
        XCTAssertFalse(sim.cancelled)
        XCTAssertEqual(aborts, [], "aborts: \(aborts.map(\.summary))")
    }

    func testAParkedCardGetsTheKeyboardBackBeforeTheDismiss() async throws {
        let sim = GrokQuestionCardSim([Self.color, Self.size])
        sim.parked = true
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color, Self.size]), with: .deny, in: id, token: UUID()),
                       .dispatched)
        XCTAssertEqual(sim.events, [.tab, .key("X")])
        XCTAssertTrue(sim.dismissed)
        XCTAssertEqual(aborts, [])
    }

    /// A person typing an answer at the keyboard: an `X` would land in their text. Refused, with
    /// nothing sent and the screen filed.
    func testAnOpenEditorIsRefusedWithNothingSent() async throws {
        let sim = GrokQuestionCardSim([Self.color])
        sim.sendCharacterKey("z")
        sim.clearEventsForTesting()
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color]), with: .deny, in: id, token: UUID()),
                       .unreadableScreen)
        XCTAssertEqual(sim.events, [])
        XCTAssertEqual(aborts.last?.check, .keyedScreenMismatch)
        XCTAssertNotNil(aborts.last?.viewport)
    }

    /// The screen shows another question than the transcript's open call: never pressed blind.
    func testAnotherQuestionsCardIsRefusedWithNothingSent() async throws {
        let sim = GrokQuestionCardSim([Self.size])
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color]), with: .deny, in: id, token: UUID()),
                       .unreadableScreen)
        XCTAssertEqual(sim.events, [])
        XCTAssertEqual(aborts.last?.check, .keyedScreenMismatch)
    }

    /// The dismiss went out and the card stayed: filed with the screen, and neither re-pressed
    /// nor escalated to Ctrl+C.
    func testALostDismissIsFiledNotRepeated() async throws {
        let sim = GrokQuestionCardSim([Self.color])
        sim.ignoreDismiss = true
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.answerPrompt(Self.prompt([Self.color]), with: .deny, in: id, token: UUID()), .dispatched)
        XCTAssertEqual(sim.events, [.key("X")])
        XCTAssertEqual(aborts.last?.check, .keyedScreenMismatch)
        XCTAssertNotNil(aborts.last?.viewport)
        XCTAssertFalse(sim.cancelled)
    }

    /// The phone's blind Abort, on a screen that does show a question card, dismisses it too.
    func testAbortOnAQuestionCardDismissesRatherThanCancels() async throws {
        let sim = GrokQuestionCardSim([Self.color])
        let (store, id) = try await makeStore(sim)
        XCTAssertEqual(store.abortPrompt(in: id, token: UUID()), .dispatched)
        XCTAssertEqual(sim.events, [.key("X")])
        XCTAssertTrue(sim.dismissed)
    }
}
