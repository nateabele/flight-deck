import XCTest
@testable import FlightDeck

final class ControlEnvironmentTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ControlEnvironmentTests.\(UUID())"

    override func setUp() { super.setUp(); defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    func testEnabledByDefaultAndCanBeTurnedOff() {
        XCTAssertTrue(ControlEnvironment.isEnabled(defaults))
        defaults.set(false, forKey: ControlEnvironment.enabledKey)
        XCTAssertFalse(ControlEnvironment.isEnabled(defaults))
    }

    func testDebugAndReleaseNeverShareASocketPath() {
        let dir = URL(fileURLWithPath: "/s")
        XCTAssertEqual(ControlEnvironment.socketURL(stateDirectory: dir, debug: false).path, "/s/control.sock")
        XCTAssertEqual(ControlEnvironment.socketURL(stateDirectory: dir, debug: true).path, "/s/control-debug.sock")
    }

    func testTokenIsStableAcrossSecretReloadAndRejectsTampering() {
        let first = ControlEnvironment.secret(defaults)
        XCTAssertEqual(first.count, 32)
        // A relaunch reads the same secret back, which is what keeps a detached tab's token valid.
        XCTAssertEqual(ControlEnvironment.secret(defaults), first)
        let session = UUID()
        let token = ControlEnvironment.token(for: session, secret: first)
        XCTAssertEqual(ControlEnvironment.session(forToken: token, secret: first), session)
        // Another session's id with this session's MAC: the forgery the HMAC exists to stop.
        let mac = token.split(separator: ".").last!
        XCTAssertNil(ControlEnvironment.session(forToken: "\(UUID().uuidString).\(mac)", secret: first))
        XCTAssertNil(ControlEnvironment.session(forToken: "garbage", secret: first))
        XCTAssertNil(ControlEnvironment.session(forToken: token, secret: Data(repeating: 1, count: 32)))
    }

    func testVariablesNameTheSessionTheSocketAndTheCaller() {
        let session = UUID()
        let secret = ControlEnvironment.secret(defaults)
        let vars = ControlEnvironment.variables(
            for: session, socket: URL(fileURLWithPath: "/s/control.sock"), secret: secret)
        XCTAssertEqual(vars["FLIGHT_DECK_SESSION_ID"], session.uuidString)
        XCTAssertEqual(vars["FLIGHT_DECK_CONTROL_SOCKET"], "/s/control.sock")
        XCTAssertEqual(ControlEnvironment.session(forToken: vars["FLIGHT_DECK_CALLER"]!, secret: secret), session)
    }
}
