import XCTest
import FleetKit
@testable import FlightDeck

/// A planning runner proves which intake it belongs to with a derived token, the way a tab proves
/// which session it is. Nothing is registered: the token is recomputed from the id and the secret.
final class RunnerTokenTests: XCTestCase {
    private let secret = Data(repeating: 7, count: 32)
    private let intake = UUID()

    func testARunnerTokenResolvesToItsIntakeAndCallerIsARunner() {
        let token = ControlEnvironment.intakeRunnerToken(for: intake, secret: secret)
        XCTAssertTrue(token.hasPrefix(ControlEnvironment.intakeRunnerPrefix + intake.uuidString + "."))
        XCTAssertEqual(ControlEnvironment.intakeRunner(forToken: token, secret: secret), intake)
        XCTAssertEqual(ControlScope.caller(token: token, secret: secret), .intakeRunner(intake))
    }

    func testATabTokenNeverVerifiesAsARunnerToken() {
        let tab = ControlEnvironment.token(for: intake, secret: secret)
        XCTAssertNil(ControlEnvironment.intakeRunner(forToken: tab, secret: secret))
        XCTAssertEqual(ControlScope.caller(token: tab, secret: secret), .session(intake))
    }

    func testARunnerTokenNeverVerifiesAsASession() {
        let token = ControlEnvironment.intakeRunnerToken(for: intake, secret: secret)
        XCTAssertNil(ControlEnvironment.session(forToken: token, secret: secret))
    }

    func testATokenMintedWithOneSecretFailsWithAnother() {
        let token = ControlEnvironment.intakeRunnerToken(for: intake, secret: secret)
        let other = Data(repeating: 9, count: 32)
        XCTAssertNil(ControlEnvironment.intakeRunner(forToken: token, secret: other))
        XCTAssertEqual(ControlScope.caller(token: token, secret: other), .invalid)
    }

    func testMalformedRunnerTokensAreRejected() {
        let prefix = ControlEnvironment.intakeRunnerPrefix
        for bad in ["", prefix, prefix + "nope.abc", prefix + intake.uuidString, prefix + intake.uuidString + ".00",
                    prefix + intake.uuidString + ".a.b"] {
            XCTAssertNil(ControlEnvironment.intakeRunner(forToken: bad, secret: secret), bad)
        }
    }

    func testARunnerTokenForIntakeXIsRefusedForIntakeY() {
        let x = intake, y = UUID(), thread = UUID()
        let runner = ControlCaller.intakeRunner(x)
        let own: [FleetCommand] = [
            .intakeTape(id: x, token: UUID(), command: "pause", stage: nil),
            .intakeThreadResolve(id: x, token: UUID(), threadID: thread),
            .intakeDiffDecide(id: x, token: UUID(), threadID: thread, diffID: UUID(), accept: true),
        ]
        let others: [FleetCommand] = [
            .intakeTape(id: y, token: UUID(), command: "pause", stage: nil),
            .intakeThreadResolve(id: y, token: UUID(), threadID: thread),
            .intakeDiffDecide(id: y, token: UUID(), threadID: thread, diffID: UUID(), accept: true),
        ]
        for level in ControlScopeLevel.allCases {
            for c in own { XCTAssertTrue(ControlScope.permits(c, level: level, caller: runner), "\(level) \(c)") }
            for c in others { XCTAssertFalse(ControlScope.permits(c, level: level, caller: runner), "\(level) \(c)") }
            XCTAssertTrue(ControlScope.permits(FleetRequest.intakeThreadGet(id: x, threadID: thread, since: nil),
                                               level: level, caller: runner))
            XCTAssertTrue(ControlScope.permits(FleetRequest.intakeDetail(id: x, ifNot: nil), level: level, caller: runner))
            XCTAssertFalse(ControlScope.permits(FleetRequest.intakeThreadGet(id: y, threadID: thread, since: nil),
                                                level: level, caller: runner))
            XCTAssertFalse(ControlScope.permits(FleetRequest.intakePlan(id: y, checkpoint: nil, changes: false),
                                                level: level, caller: runner))
        }
    }

    func testARunnerIsRefusedEverythingNotAboutItsOwnIntake() {
        let runner = ControlCaller.intakeRunner(intake)
        for level in ControlScopeLevel.allCases {
            XCTAssertFalse(ControlScope.permits(FleetCommand.viewing(session: nil), level: level, caller: runner))
            XCTAssertFalse(ControlScope.permits(FleetCommand.closeSession(id: UUID()), level: level, caller: runner))
            XCTAssertFalse(ControlScope.permits(FleetCommand.swarmPause(project: UUID()), level: level, caller: runner))
            XCTAssertFalse(ControlScope.permits(FleetRequest.hostList, level: level, caller: runner))
        }
    }
}
