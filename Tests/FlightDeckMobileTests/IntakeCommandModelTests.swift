import FleetKit
import XCTest
@testable import FlightDeckMobile

/// Records every intake command and answers on demand — or before `sendIntake` returns, the
/// `.disconnected` path `FleetConnector.send(_:then:)` takes deliberately.
@MainActor
private final class StubCommander: IntakeCommanding {
    private(set) var commands: [FleetCommand] = []
    private var pending: [(Result<Void, FleetRequestError>) -> Void] = []
    var answerBeforeReturning: Result<Void, FleetRequestError>?

    var tokens: [UUID] {
        commands.compactMap { if case .intakeDefaultPlay(_, let t, _) = $0 { return t } else { return nil } }
    }

    func sendIntake(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        commands.append(command)
        if let answer = answerBeforeReturning { return completion(answer) }
        pending.append(completion)
    }

    func answer(_ result: Result<Void, FleetRequestError>) {
        guard !pending.isEmpty else { return XCTFail("no command was sent") }
        pending.removeFirst()(result)
    }
}

@MainActor
final class IntakeCommandModelTests: XCTestCase {
    private let intake = UUID()

    private func model(_ c: StubCommander, timeout: Duration = .seconds(10)) -> IntakeCommandModel {
        IntakeCommandModel(intake: intake, commander: c, timeout: timeout)
    }

    private func play(_ m: IntakeCommandModel, onAck: @escaping () -> Void = {}) {
        let id = intake
        m.send(.defaultPlay("auto"), command: { .intakeDefaultPlay(id: id, token: $0, mode: "auto") }, onAck: onAck)
    }

    func testInFlightImmediatelyThenClearedOnAck() {
        let c = StubCommander(), m = model(c)
        var acked = 0
        play(m) { acked += 1 }
        XCTAssertEqual(m.inFlight, [.defaultPlay("auto")])
        c.answer(.success(()))
        XCTAssertTrue(m.inFlight.isEmpty)
        XCTAssertEqual(acked, 1)
        XCTAssertNil(m.message)
    }

    func testErrSetsMappedMessageAndClears() {
        let c = StubCommander(), m = model(c)
        var acked = 0
        play(m) { acked += 1 }
        c.answer(.failure(.server(code: "intake_moved_on")))
        XCTAssertTrue(m.inFlight.isEmpty)
        XCTAssertEqual(m.message, "This intake has moved on.")
        XCTAssertEqual(acked, 0)
        m.clearMessage()
        XCTAssertNil(m.message)
    }

    func testSynchronousDisconnectedSetsMessageAndNoLaterTimeout() async {
        let c = StubCommander(); c.answerBeforeReturning = .failure(.disconnected)
        let m = model(c, timeout: .milliseconds(50))
        play(m)
        XCTAssertEqual(m.message, "Not connected to your Mac, so this wasn't sent.")
        XCTAssertTrue(m.inFlight.isEmpty)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(m.message, "Not connected to your Mac, so this wasn't sent.")
    }

    func testTimeoutSetsCouldntReach() async {
        let c = StubCommander()
        let m = model(c, timeout: .milliseconds(50))
        play(m)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(m.message, "Couldn't reach your Mac.")
        XCTAssertTrue(m.inFlight.isEmpty)
        c.answer(.success(()))  // a late ack is ignored
        XCTAssertEqual(m.message, "Couldn't reach your Mac.")
    }

    func testDuplicateInFlightSendsNothing() {
        let c = StubCommander(), m = model(c)
        play(m); play(m)
        XCTAssertEqual(c.commands.count, 1)
    }

    func testEachSendCarriesAFreshToken() {
        let c = StubCommander(), m = model(c)
        play(m)
        c.answer(.success(()))
        play(m)
        XCTAssertEqual(Set(c.tokens).count, 2)
    }

    func testCopyTable() {
        let table: [(FleetRequestError?, String)] = [
            (nil, "Couldn't reach your Mac."),
            (.disconnected, "Not connected to your Mac, so this wasn't sent."),
            (.server(code: "intake_moved_on"), "This intake has moved on."),
            (.server(code: "not_allowed"), "That isn't possible right now."),
            (.server(code: "note_consumed"), "A round has already read that note."),
            (.server(code: "empty_note"), "Write something first."),
            (.server(code: "unknown_intake"), "This intake is no longer on your Mac."),
            (.server(code: "unknown_checkpoint"), "The plan changed — reopen it and try again."),
            (.server(code: "unknown_block"), "The plan changed — reopen it and try again."),
            (.server(code: "weird"), "Your Mac wouldn't do that (weird)."),
        ]
        for (error, copy) in table { XCTAssertEqual(CommandCopy.message(for: error), copy) }
    }

    func testFlightControlVendsOneModelPerIntakeAndResetClears() {
        let fleet = FleetModel(store: InMemoryPairedMacStore())
        let fc = fleet.flightControl!
        let a = fc.commands(for: intake)
        XCTAssertTrue(a === fc.commands(for: intake))
        fc.reset()
        XCTAssertFalse(a === fc.commands(for: intake))
    }
}
