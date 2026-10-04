import XCTest
@testable import HostKit

final class PairingWindowTests: XCTestCase {
    func testArmReplacesPreviousCode() {
        let w = PairingWindow()
        _ = w.arm(codeText: "AAAA-BBBB-CCCC")
        _ = w.arm(codeText: "DDDD-EEEE-FFFF")
        XCTAssertFalse(w.consume(codeText: "AAAA-BBBB-CCCC"))
        XCTAssertTrue(w.consume(codeText: "DDDD-EEEE-FFFF"))
        XCTAssertFalse(w.consume(codeText: "DDDD-EEEE-FFFF"), "a code pairs exactly one controller")
    }

    func testExpiresAfterLifetime() {
        let clock = Clock()
        let w = PairingWindow(now: { clock.now }, lifetime: 120)
        let expiry = w.arm(codeText: "AAAA-BBBB-CCCC")
        XCTAssertEqual(expiry, Date(timeIntervalSince1970: 120))
        XCTAssertEqual(w.current?.code, "AAAA-BBBB-CCCC")
        clock.now += 121
        XCTAssertNil(w.current)
        XCTAssertFalse(w.consume(codeText: "AAAA-BBBB-CCCC"))
    }

    func testCancelClosesTheWindow() {
        let w = PairingWindow()
        _ = w.arm(codeText: "AAAA-BBBB-CCCC")
        w.cancel()
        XCTAssertNil(w.current)
        XCTAssertFalse(w.consume(codeText: "AAAA-BBBB-CCCC"))
    }

    /// A user types the code by hand: case and dashes must not decide whether it pairs.
    func testConsumeIgnoresCaseAndDashes() {
        let w = PairingWindow()
        _ = w.arm(codeText: "AAAA-BBBB-CCCC")
        XCTAssertTrue(w.consume(codeText: "aaaabbbbcccc"))
    }

    func testWrongCodeDoesNotBurnTheWindow() {
        let w = PairingWindow()
        _ = w.arm(codeText: "AAAA-BBBB-CCCC")
        XCTAssertFalse(w.consume(codeText: "ZZZZ-ZZZZ-ZZZZ"))
        XCTAssertTrue(w.consume(codeText: "AAAA-BBBB-CCCC"))
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
    }
}
