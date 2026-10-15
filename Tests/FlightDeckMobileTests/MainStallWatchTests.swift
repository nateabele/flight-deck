import XCTest
@testable import FlightDeckMobile

/// The freeze watch on a real freeze: the main thread is blocked here, on purpose, and the
/// watch must log the stall and a stack taken while it lasted. A watch that only ever saw a
/// healthy main thread would pass any test that did not do this.
@MainActor
final class MainStallWatchTests: XCTestCase {
    private var perfLog: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phone.log")
    }

    func testABlockedMainThreadIsLoggedWithItsStack() async throws {
        MainStallWatch.start()
        let before = (try? Data(contentsOf: perfLog).count) ?? 0
        usleep(1_500_000)

        var logged = ""
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            let data = (try? Data(contentsOf: perfLog)) ?? Data()
            logged = String(decoding: data.dropFirst(before), as: UTF8.self)
            if logged.contains("main stall ms=") { break }
        }
        let stall = try XCTUnwrap(
            logged.split(separator: "\n").first { $0.contains("main stall ms=") },
            "no stall logged:\n\(logged)"
        )
        let ms = Int(stall.split(separator: "=")[1].split(separator: " ")[0]) ?? 0
        // A lower bound: the watch times from its own ping, which can land a poll or more
        // after the block began (446 ms of a 700 ms block, measured).
        XCTAssertGreaterThanOrEqual(ms, 300, String(stall))
        let stack = try XCTUnwrap(logged.split(separator: "\n").first { $0.contains("stack[0]") })
        // Taken while the thread sat in `usleep`, so the innermost frames are the kernel's
        // sleep, and the walk carries on out through `usleep` into the function that called it.
        XCTAssertTrue(stack.contains("libsystem_kernel"), String(stack))
        XCTAssertTrue(stack.contains("usleep"), String(stack))
        XCTAssertTrue(stack.contains("FlightDeckMobileTests+0x"), String(stack))
    }

    func testTheArmedLineNamesTheBuild() {
        XCTAssertTrue(StackSymbols.appImageSummary().hasPrefix("uuid="))
        XCTAssertNotEqual(StackSymbols.appImageSummary(), "uuid=?")
    }
}
