import FleetKit
import XCTest
@testable import FlightDeckMobile

/// Records each answer sent and answers it on demand.
@MainActor
private final class Commander: IntakeCommanding {
    private(set) var commands: [FleetCommand] = []
    private var pending: [(Result<Void, FleetRequestError>) -> Void] = []

    func sendIntake(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {
        commands.append(command)
        pending.append(completion)
    }

    func answer(_ result: Result<Void, FleetRequestError>) {
        guard !pending.isEmpty else { return XCTFail("no command was sent") }
        pending.removeFirst()(result)
    }
}

/// When the phone shows the answer form, when it reads "Sending…", and when it starts again.
@MainActor
final class AnswerFormModelTests: XCTestCase {
    private let intake = UUID()
    private let question = WireStructuredQuestion(
        id: "q1", text: "Which?", kind: "single",
        options: [WireOption(id: "a", label: "A"), WireOption(id: "b", label: "B")], recommended: ["a"], allowOther: true)

    private func detail(state: String = "needsAnswers", flag: Bool? = true, round: Int = 0,
                        digest: String = "d1", questions: [WireStructuredQuestion]? = nil) -> WireIntakeDetail {
        WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: intake, title: "T", state: state, needsAttention: true,
                                       createdAt: Date(timeIntervalSinceReferenceDate: 1)),
            intent: "x",
            questions: WireQuestions(open: ["Which?"], answered: [], round: round,
                                     structured: questions ?? [question], digest: digest),
            servedAt: Date(timeIntervalSinceReferenceDate: 2), structuredQuestions: flag)
    }

    private func drafts() -> AnswerDraftStore {
        let name = "answer-drafts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return AnswerDraftStore(defaults: defaults)
    }

    func testNoFormWithoutTheFlagOrOutsideNeedsAnswers() {
        XCTAssertNil(AnswerFormModel.openRound(detail(flag: nil)), "an older Mac drops the socket on intake.answer")
        XCTAssertNil(AnswerFormModel.openRound(detail(flag: false)))
        XCTAssertNil(AnswerFormModel.openRound(detail(state: "triaging")))
        XCTAssertNil(AnswerFormModel.openRound(nil))
        let open = AnswerFormModel.openRound(detail(round: 1))
        XCTAssertEqual(open?.digest, "d1")
        XCTAssertEqual(open?.title, "Round 2 · 1 question")
    }

    /// Sending holds through the ack (the detail still reads needsAnswers until triage moves it)
    /// and ends when the state changes; a later round that happens to ask the same thing is not
    /// shown as already sent.
    func testSendingHoldsUntilTheAckAndTheStateChange() throws {
        let c = Commander(), commands = IntakeCommandModel(intake: intake, commander: c)
        let form = AnswerFormModel(intake: intake)
        let open = try XCTUnwrap(AnswerFormModel.openRound(detail()))
        XCTAssertFalse(form.sending(open, inFlight: commands.inFlight))
        var refreshed = 0
        form.send([question.initialAnswer], for: open, via: commands, refresh: { refreshed += 1 })
        XCTAssertTrue(form.sending(open, inFlight: commands.inFlight), "in flight")
        c.answer(.success(()))
        XCTAssertEqual(refreshed, 1)
        XCTAssertTrue(form.sending(open, inFlight: commands.inFlight), "acked, the Mac not yet moved on")
        form.observe(detail())
        XCTAssertTrue(form.sending(open, inFlight: commands.inFlight), "the same round, still waiting")
        form.observe(detail(state: "triaging"))
        form.observe(detail())
        XCTAssertFalse(form.sending(open, inFlight: commands.inFlight), "a later round asking the same thing")
    }

    func testANewDigestResetsTheForm() throws {
        let c = Commander(), commands = IntakeCommandModel(intake: intake, commander: c)
        let form = AnswerFormModel(intake: intake)
        let first = try XCTUnwrap(AnswerFormModel.openRound(detail(round: 0, digest: "d1")))
        form.send([question.initialAnswer], for: first, via: commands, refresh: {})
        c.answer(.success(()))
        let next = try XCTUnwrap(AnswerFormModel.openRound(detail(round: 1, digest: "d2")))
        form.observe(detail(round: 1, digest: "d2"))
        XCTAssertNotEqual(form.identity(next), form.identity(first))
        XCTAssertFalse(form.sending(next, inFlight: commands.inFlight))
    }

    /// The Mac's retry clears the exchanges: the new round is index 0 again with different
    /// questions. Only the digest tells them apart, so the form must not keep the old answers or
    /// read "Sending…".
    func testAfterARetryTheSameRoundIndexWithADifferentDigestResets() throws {
        let c = Commander(), commands = IntakeCommandModel(intake: intake, commander: c)
        let form = AnswerFormModel(intake: intake)
        let before = try XCTUnwrap(AnswerFormModel.openRound(detail(round: 0, digest: "d1")))
        form.send([question.initialAnswer], for: before, via: commands, refresh: {})
        c.answer(.success(()))
        let after = try XCTUnwrap(AnswerFormModel.openRound(detail(round: 0, digest: "d9")))
        XCTAssertNotEqual(form.identity(after), form.identity(before))
        XCTAssertFalse(form.sending(after, inFlight: commands.inFlight))
    }

    /// The Mac refused the round as replaced: the form starts again from the refreshed one, even
    /// before that refresh brings a different digest.
    func testAStaleRefusalStartsTheFormAgain() throws {
        let c = Commander(), commands = IntakeCommandModel(intake: intake, commander: c)
        let form = AnswerFormModel(intake: intake)
        let open = try XCTUnwrap(AnswerFormModel.openRound(detail()))
        let identity = form.identity(open)
        var refreshed = 0
        form.send([question.initialAnswer], for: open, via: commands, refresh: { refreshed += 1 })
        c.answer(.failure(.server(code: "stale_questions")))
        XCTAssertEqual(refreshed, 1)
        XCTAssertNotEqual(form.identity(open), identity)
        XCTAssertFalse(form.sending(open, inFlight: commands.inFlight))
    }

    /// A lone single-select question: one tap is a whole answer, yet the tap only picks. Nothing
    /// goes to the Mac until Send, so a thumb landing on an option on its way to the Other field
    /// sends nothing (the prompt card's rule since e2b55cb0).
    func testALoneSingleSelectTapPicksAndOnlySendCommits() throws {
        let c = Commander(), commands = IntakeCommandModel(intake: intake, commander: c)
        let form = AnswerFormModel(intake: intake)
        let open = try XCTUnwrap(AnswerFormModel.openRound(detail()))
        XCTAssertEqual(open.questions.count, 1)
        let start = form.initialAnswers(open)[0]

        let picked = StructuredQuestionForm.picking("b", in: start, multi: false)
        XCTAssertEqual(picked.selected, ["b"])
        XCTAssertTrue(question.isComplete(picked), "Send is ready")
        XCTAssertTrue(c.commands.isEmpty, "the tap sent nothing")
        XCTAssertFalse(form.sending(open, inFlight: commands.inFlight))

        let again = StructuredQuestionForm.picking("a", in: picked, multi: false)
        XCTAssertEqual(again.selected, ["a"], "a second tap changes the pick, still unsent")
        XCTAssertTrue(c.commands.isEmpty)

        form.send([again], for: open, via: commands, refresh: {})
        XCTAssertEqual(c.commands, [.intakeAnswer(id: intake, token: try XCTUnwrap(Self.token(c.commands.first)),
                                                  round: 0, digest: "d1", answers: [again])])
    }

    private static func token(_ command: FleetCommand?) -> UUID? {
        if case .intakeAnswer(_, let token, _, _, _)? = command { return token }
        return nil
    }

    // MARK: drafts

    func testTheFormStartsFromThisRoundsKeptAnswersAndASendClearsThem() throws {
        let store = drafts()
        let c = Commander(), commands = IntakeCommandModel(intake: intake, commander: c)
        let open = try XCTUnwrap(AnswerFormModel.openRound(detail()))
        let chosen = [WireStructuredAnswer(questionID: "q1", selected: [], other: "neither")]
        AnswerFormModel(intake: intake, drafts: store).keep(chosen, for: open)

        // A relaunch: a new model over the same store.
        let relaunched = AnswerFormModel(intake: intake, drafts: store)
        XCTAssertEqual(relaunched.initialAnswers(open), chosen)
        let retried = try XCTUnwrap(AnswerFormModel.openRound(detail(digest: "d9")))
        XCTAssertEqual(relaunched.initialAnswers(retried), [question.initialAnswer], "another round's answers")

        relaunched.send(chosen, for: open, via: commands, refresh: {})
        XCTAssertNotNil(store.drafts(intake: intake, digest: "d1"), "kept until the Mac takes them")
        c.answer(.success(()))
        XCTAssertNil(store.drafts(intake: intake, digest: "d1"))
        XCTAssertEqual(AnswerFormModel(intake: intake, drafts: store).initialAnswers(open), [question.initialAnswer])
    }

    /// Kept answers that no longer fit the round's questions (ids changed, a question added) are
    /// not used: the form starts from the recommended options.
    func testKeptAnswersThatDoNotFitAreIgnored() throws {
        let store = drafts()
        let open = try XCTUnwrap(AnswerFormModel.openRound(detail()))
        store.save([WireStructuredAnswer(questionID: "zz", other: "x")], intake: intake, digest: "d1")
        XCTAssertEqual(AnswerFormModel(intake: intake, drafts: store).initialAnswers(open), [question.initialAnswer])
    }
}

/// Answers chosen on the phone survive a relaunch, per intake and round, until they are sent.
final class AnswerDraftStoreTests: XCTestCase {
    private func store() -> (AnswerDraftStore, UserDefaults) {
        let name = "answer-drafts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return (AnswerDraftStore(defaults: defaults), defaults)
    }

    func testSavedPerIntakeAndDigestAndClearedOnSend() {
        let (drafts, defaults) = store()
        let one = UUID(), two = UUID()
        let answers = [WireStructuredAnswer(questionID: "q1", selected: ["a", "b"], other: "c")]
        drafts.save(answers, intake: one, digest: "d1")
        XCTAssertEqual(AnswerDraftStore(defaults: defaults).drafts(intake: one, digest: "d1"), answers, "a relaunch")
        XCTAssertNil(drafts.drafts(intake: one, digest: "d2"), "a different round gets nothing")
        XCTAssertNil(drafts.drafts(intake: two, digest: "d1"), "a different intake gets nothing")

        drafts.clear(intake: one, digest: "d2")
        XCTAssertEqual(drafts.drafts(intake: one, digest: "d1"), answers, "clearing another round leaves this one")
        drafts.clear(intake: one, digest: "d1")
        XCTAssertNil(drafts.drafts(intake: one, digest: "d1"))
    }

    func testANewRoundReplacesTheOldAndPurgeTakesEverything() {
        let (drafts, _) = store()
        let one = UUID(), two = UUID()
        drafts.save([WireStructuredAnswer(questionID: "q1", other: "old")], intake: one, digest: "d1")
        drafts.save([WireStructuredAnswer(questionID: "q1", other: "new")], intake: one, digest: "d2")
        XCTAssertNil(drafts.drafts(intake: one, digest: "d1"))
        XCTAssertEqual(drafts.drafts(intake: one, digest: "d2"), [WireStructuredAnswer(questionID: "q1", other: "new")])
        drafts.save([WireStructuredAnswer(questionID: "q1", other: "x")], intake: two, digest: "d1")
        drafts.purgeAll()
        XCTAssertNil(drafts.drafts(intake: one, digest: "d2"))
        XCTAssertNil(drafts.drafts(intake: two, digest: "d1"))
    }
}
