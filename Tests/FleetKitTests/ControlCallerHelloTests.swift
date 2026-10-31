import FleetKit
import XCTest

final class ControlCallerHelloTests: XCTestCase {
    private let thread = UUID(uuidString: "01A1708D-5E50-7900-BCCB-03402EB04091")!

    func testAShellTabSendsItsTokenUnchanged() {
        XCTAssertEqual(ControlCallerHello.compose(environment: ["FLIGHT_DECK_CALLER": "TAB.sig"]), "TAB.sig")
        XCTAssertNil(ControlCallerHello.compose(environment: [:]))
    }

    func testACodexCommandNamesItsThread() {
        let caller = ControlCallerHello.compose(environment: [
            "FLIGHT_DECK_CALLER": "TAB.sig", "CODEX_THREAD_ID": thread.uuidString.lowercased(),
        ])
        let split = ControlCallerHello.split(caller)
        XCTAssertEqual(split.token, "TAB.sig")
        XCTAssertEqual(split.codexThread, thread)
    }

    /// A daemon Flight Deck started itself has no tab token; the thread still names the tab.
    func testAThreadWithoutATokenIsStillSent() {
        let split = ControlCallerHello.split(ControlCallerHello.compose(environment: ["CODEX_THREAD_ID": thread.uuidString]))
        XCTAssertNil(split.token)
        XCTAssertEqual(split.codexThread, thread)
    }

    /// A thread id that is not a UUID is dropped rather than sent: the token alone is the safe
    /// answer, never a caller the app cannot verify.
    func testAMalformedThreadIsIgnored() {
        XCTAssertEqual(ControlCallerHello.compose(environment: ["FLIGHT_DECK_CALLER": "TAB.sig", "CODEX_THREAD_ID": "nope"]),
                       "TAB.sig")
        XCTAssertEqual(ControlCallerHello.split("TAB.sig").token, "TAB.sig")
        XCTAssertNil(ControlCallerHello.split("TAB.sig").codexThread)
        XCTAssertNil(ControlCallerHello.split(nil).token)
    }
}
