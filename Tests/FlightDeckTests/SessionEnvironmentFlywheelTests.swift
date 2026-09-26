import XCTest
@testable import FlightDeck

@MainActor
final class SessionEnvironmentFlywheelTests: XCTestCase {
    private func makeStore() -> PreferencesStore {
        PreferencesStore(persistence: nil)
    }

    func testIdentityAddsAgentNameVars() {
        let env = makeStore().sessionEnvironment(
            for: nil, flywheel: FlywheelIdentity(agentName: "BlueFalcon", project: "/tmp/p"))
        XCTAssertEqual(env["AGENT_NAME"], "BlueFalcon")
        XCTAssertEqual(env["AGENT_MAIL_AGENT"], "BlueFalcon")
        XCTAssertEqual(env["AGENT_MAIL_PROJECT"], "/tmp/p")
    }

    func testNoIdentityLeavesEnvUnchanged() {
        let store = makeStore()
        let base = store.sessionEnvironment(for: nil)
        let same = store.sessionEnvironment(for: nil, flywheel: nil)
        XCTAssertEqual(base, same)
        XCTAssertNil(same["AGENT_NAME"])
    }
}
