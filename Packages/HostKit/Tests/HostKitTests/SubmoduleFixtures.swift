import Foundation
import XCTest

/// A gate a test closes on a dispatch thread (inside a git step, through a test seam) and opens
/// from the test. Blocking happens off the cooperative pool, as the real git does.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var holders = 0
    private let opened = DispatchSemaphore(value: 0)

    /// Blocks the calling thread until `open()`. Returns at once once opened.
    func hold() {
        let wait: Bool = lock.withLock {
            guard !isOpen else { return false }
            holders += 1
            return true
        }
        if wait { opened.wait() }
    }

    func open() {
        let n: Int = lock.withLock {
            guard !isOpen else { return 0 }
            isOpen = true
            return holders
        }
        for _ in 0..<n { opened.signal() }
    }

    var held: Int { lock.withLock { holders } }

    /// Suspends until at least one thread is held, or fails after `seconds`.
    func waitUntilHeld(seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while held == 0 {
            if Date() > deadline { XCTFail("nothing reached the gate", file: file, line: line); throw CancellationError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// A flag set by one task and polled, with a deadline, by another: a task blocked inside a
/// lock cannot be cancelled, so a test that awaited it directly would hang instead of failing.
final class Done: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }

    func wait(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !isSet && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return isSet
    }
}

/// Fixtures cross into the tasks a concurrency test starts; each is used by one task at a time.
extension TempRepo: @unchecked Sendable {}
