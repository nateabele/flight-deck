import XCTest
import IntakeKit
@testable import FlightDeck

/// I4: what a thread turn's agent CLI presents to the control socket. With no token a caller is
/// the unscoped human, so the agent carries `ThreadTurnExecutor.agentCaller` instead, and the
/// socket must read that as invalid — failing closed under every scoped level.
final class ThreadAgentCallerTests: XCTestCase {
    func testTheThreadAgentsCallerIsInvalid() {
        let secret = Data(repeating: 7, count: 32)
        let caller = ControlScope.caller(token: ThreadTurnExecutor.agentCaller, secret: secret)
        guard case .invalid = caller else { return XCTFail("\(caller)") }
        XCTAssertEqual(ControlEnvironment.callerVariable, "FLIGHT_DECK_CALLER", "the variable the executor sets")
    }
}
