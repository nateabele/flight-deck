import XCTest
import IntakeKit
@testable import FlightDeck

/// "Composer-ready" is not an event FD receives — it is `submitPrompt` stopping saying
/// `notRunning`, and then the queued prompt leaving the queue. These pin both phases and the
/// 2-minute bound, and that a timed-out prompt is WITHDRAWN: left queued, it would be typed into
/// the agent minutes later, after its claim had already been returned to open.
@MainActor
final class PromptDeliveryTests: XCTestCase {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_790_000_000) }

    /// `Result<Void, _>` is not `Equatable` (`Void` is not), so failures are compared through this.
    private func failure(_ r: Result<Void, SpawnError>) -> SpawnError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    private func delivery(answers: [SessionStore.PromptDispatch], queuedFor ticks: Int = 0,
                          clock: Clock, withdrawn: @escaping (UUID) -> Void = { _ in }) -> PromptDelivery {
        var answers = answers
        var remaining = ticks
        return PromptDelivery(
            submit: { _, _, _ in answers.isEmpty ? .notRunning : answers.removeFirst() },
            pending: { _, _ in defer { remaining -= 1 }; return remaining > 0 },
            withdraw: { token, _ in withdrawn(token) },
            sleep: { clock.now += Double($0.components.seconds) },
            now: { clock.now }, timeout: 120)
    }

    func testSentImmediatelyIsSuccess() async {
        let r = await delivery(answers: [.sent], clock: Clock()).deliver("go", to: UUID())
        XCTAssertNoThrow(try r.get())
    }

    func testNotRunningThenSentWaitsForTheComposer() async {
        let clock = Clock()
        let r = await delivery(answers: [.notRunning, .notRunning, .sent], clock: clock).deliver("go", to: UUID())
        XCTAssertNoThrow(try r.get())
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1_790_000_002)
    }

    func testQueuedWaitsUntilTyped() async {
        let clock = Clock()
        let r = await delivery(answers: [.queued], queuedFor: 3, clock: clock).deliver("go", to: UUID())
        XCTAssertNoThrow(try r.get())
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1_790_000_003)
    }

    func testNoComposerWithinTwoMinutesTimesOut() async {
        let r = await delivery(answers: [], clock: Clock()).deliver("go", to: UUID())
        XCTAssertEqual(failure(r), .composerTimeout)
    }

    func testAQueuedPromptStillUntypedAtTheDeadlineIsWithdrawn() async {
        var withdrawn: [UUID] = []
        let r = await delivery(answers: [.queued], queuedFor: 1_000, clock: Clock(),
                               withdrawn: { withdrawn.append($0) }).deliver("go", to: UUID())
        XCTAssertEqual(failure(r), .composerTimeout)
        XCTAssertEqual(withdrawn.count, 1)
    }

    func testRefusalsAreLaunchFailures() async {
        let gone = await delivery(answers: [.unknownSession], clock: Clock()).deliver("go", to: UUID())
        XCTAssertEqual(failure(gone), .launchFailed("the tab is gone"))
        let rejected = await delivery(answers: [.rejected(.tooLong)], clock: Clock()).deliver("go", to: UUID())
        XCTAssertEqual(failure(rejected), .launchFailed("the prompt was refused: prompt_too_long"))
    }
}
