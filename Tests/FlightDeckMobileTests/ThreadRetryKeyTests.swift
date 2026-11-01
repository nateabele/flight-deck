import FleetKit
import XCTest
@testable import FlightDeckMobile

/// Holds every answer until the test gives it, so a send can "time out" after it was written.
private final class HeldCommander: IntakeCommanding {
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

private final class NoFetcher: IntakeFetching {
    func intakeDetail(_ id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void) {}
    func intakePlan(_ id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void) {}
}

/// C-I1 and C-6: a retry token stands for ONE decision. A ✓ whose ack was lost is not a ✗'s
/// token, answers to one turn are not the next turn's, and an opening send keeps its token for
/// as long as its draft does, so a late Retry never opens a second thread.
@MainActor
final class ThreadRetryKeyTests: XCTestCase {
    private let intake = UUID()
    private var commander: HeldCommander!
    private var model: FlightControlModel!

    override func setUp() {
        super.setUp()
        commander = HeldCommander()
        model = FlightControlModel(fetcher: NoFetcher(), commander: commander)
    }

    private func token(_ command: FleetCommand) -> UUID? {
        switch command {
        case .intakeDiffDecide(_, let token, _, _, _), .intakeThreadSend(_, let token, _, _, _): token
        case .intakeThreadAnswer(_, let token, _, _, _): token
        default: nil
        }
    }

    /// Scenario 1: the ✓ landed but its ack was lost; the ✗ that follows is a new decision with
    /// its own token, which the Mac refuses as `diff_decided` rather than acking as a duplicate.
    func testARejectAfterALostAcceptCarriesItsOwnToken() {
        let diff = WirePendingDiff(id: UUID(), thread: UUID(), checkpoint: 1, old: "a", new: "b", state: "pending")
        model.decideDiff(diff, accept: true, intake: intake)
        commander.answer(.failure(.disconnected))
        model.decideDiff(diff, accept: false, intake: intake)
        XCTAssertEqual(commander.commands.count, 2)
        XCTAssertNotEqual(token(commander.commands[0]), token(commander.commands[1]))

        // The same ✓ again is the retry it is, under the kept token.
        model.decideDiff(diff, accept: true, intake: intake)
        guard commander.commands.count == 3 else { return XCTFail("the ✓ retry was not sent") }
        XCTAssertEqual(token(commander.commands[2]), token(commander.commands[0]))
    }

    /// Scenario 2: answers to turn 1 timed out but landed; turn 2 asks again. Its answers get a
    /// fresh token and name their turn, so the Mac neither drops them as a duplicate nor puts
    /// them on the wrong question.
    func testAnswersToTheNextTurnCarryTheirOwnTokenAndTurn() {
        let thread = UUID()
        let answers = [WireStructuredAnswer(questionID: "q1", selected: ["a"])]
        model.answerThread(thread, answers: answers, turn: 1, intake: intake)
        commander.answer(.failure(.disconnected))
        model.answerThread(thread, answers: answers, turn: 2, intake: intake)
        XCTAssertEqual(commander.commands.count, 2)
        XCTAssertNotEqual(token(commander.commands[0]), token(commander.commands[1]))
        guard case .intakeThreadAnswer(_, _, _, _, let turn) = commander.commands[1] else { return XCTFail() }
        XCTAssertEqual(turn, 2)
    }

    /// C-6: once a draft that opens a thread has been sent, every Retry of it carries the same
    /// token, even after the command model has forgotten its own (past the retry window, or
    /// after a definitive refusal), so a send that did land is never opened twice.
    func testAnOpeningRetryReusesTheDraftsToken() {
        let draft = ThreadDraft(threadID: nil, anchor: nil, text: "Why Friday?")
        model.sendThread(draft, intake: intake)
        commander.answer(.failure(.server(code: "write_failed")))
        model.sendThread(draft, intake: intake)
        XCTAssertEqual(commander.commands.count, 2)
        XCTAssertEqual(token(commander.commands[0]), token(commander.commands[1]))
    }
}
