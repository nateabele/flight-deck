import XCTest
@testable import HostKit
#if os(macOS)
import HostKitDarwin
import IOKit.pwr_mgt
#endif

final class PowerAndConsoleTests: XCTestCase {
    func testReleaseIsIdempotent() {
        let count = Counter()
        let assertion = PowerAssertion { count.bump() }
        assertion.release()
        assertion.release()
        XCTAssertEqual(count.value, 1, "a run's exit and its cancel can both release")
    }

    /// The inhibitor's lifetime is tied to a pipe, not a pid: closing stdin ends it, and so
    /// does hostd dying, so a crash can never leave the host unable to sleep.
    func testSystemdInhibitHoldsUntilReleased() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inhibit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("systemd-inhibit")
        try """
        #!/bin/sh
        echo "$@" > "\(dir.path)/args"
        cat > /dev/null
        echo released > "\(dir.path)/done"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let power = SystemdInhibitAssertions(executable: fake.path)
        let held = power.hold(.idleSleep, reason: "run r1")
        let args = dir.appendingPathComponent("args"), done = dir.appendingPathComponent("done")
        XCTAssertTrue(waitFor { FileManager.default.fileExists(atPath: args.path) })
        let argLine = try String(contentsOf: args, encoding: .utf8)
        XCTAssertTrue(argLine.contains("--what=sleep"), argLine)
        XCTAssertTrue(argLine.contains("run r1"), argLine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: done.path), "held until released")

        held.release()
        XCTAssertTrue(waitFor { FileManager.default.fileExists(atPath: done.path) })
    }

    func testSystemdInhibitAbsentHoldsNothing() {
        SystemdInhibitAssertions(executable: nil).hold(.idleSleep, reason: "x").release()
    }

    #if os(Linux)
    func testLinuxConsoleIsUnsupported() {
        XCTAssertEqual(ConsoleSession.platformDefault.current(), .unsupported)
    }
    #endif

    #if os(macOS)
    func testIOKitAssertionIsVisibleWhileHeld() throws {
        let reason = "flightdeck test \(UUID().uuidString)"
        let held = IOKitPowerAssertions().hold(.idleSleep, reason: reason)
        XCTAssertTrue(assertionNames().contains(reason))
        held.release()
        XCTAssertFalse(assertionNames().contains(reason))
    }

    func testDarwinConsoleParsesTheSessionDictionary() {
        // No dictionary: hostd is outside any GUI session (a LaunchDaemon, or ssh only).
        XCTAssertEqual(DarwinConsoleSession.parse(nil),
                       ConsoleSession(supported: true, consoleUser: false, locked: false))
        XCTAssertEqual(DarwinConsoleSession.parse(["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]),
                       ConsoleSession(supported: true, consoleUser: true, locked: false))
        XCTAssertEqual(DarwinConsoleSession.parse(["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true,
                                                   "CGSSessionScreenIsLocked": true]),
                       ConsoleSession(supported: true, consoleUser: true, locked: true))
        // Fast user switching: the session exists but another user has the console.
        XCTAssertEqual(DarwinConsoleSession.parse(["kCGSSessionOnConsoleKey": false, "kCGSessionLoginDoneKey": true]),
                       ConsoleSession(supported: true, consoleUser: false, locked: false))
    }

    func testDarwinConsoleIsSupported() {
        XCTAssertTrue(DarwinConsoleSession().current().supported)
    }

    private func assertionNames() -> [String] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPid = raw?.takeRetainedValue() as? [AnyHashable: [[String: Any]]] else { return [] }
        return byPid.values.flatMap { $0 }.compactMap { $0[kIOPMAssertionNameKey] as? String }
    }
    #endif

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }
}
