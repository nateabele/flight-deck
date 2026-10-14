import Foundation
@testable import FlightDeck

/// Turns the main run loop until `condition` holds or `timeout` passes; returns whether it held.
///
/// For tests that act, then need the run loop (a debounce, a coalescing timer, a queued
/// observer block) to deliver the result. A fixed `RunLoop.run(until: now + 0.05)` is a guess
/// that the loop gets its turn in 50 ms, which a loaded machine breaks. Assert on the real
/// condition afterwards, as before, so a failure still names what did not happen.
@discardableResult
func spinRunLoop(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

/// Gives the main run loop `seconds`, then makes sure everything already queued on the main
/// queue has run, including work that hops again. For the "let the deferred commit land" pump
/// helpers: `run(until:)` alone returns when its window closes, and on a loaded machine the
/// queued block may not have had its turn inside it. Main queue blocks run in order, so a
/// sentinel that has run means everything ahead of it has too.
func settleMainRunLoop(_ seconds: TimeInterval = 0.05, hops: Int = 3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    for _ in 0..<hops {
        var reached = false
        DispatchQueue.main.async { reached = true }
        spinRunLoop { reached }
    }
}

/// Turns the run loop until the render counts (`RenderProbe`) stop moving: three quiet 150 ms
/// turns. A fixed pause is a guess about how long first-appearance work takes; on a loaded
/// machine it spills into the window a test is about to count.
@MainActor
func settleRenders() {
    var last = RenderProbe.counts
    var quiet = 0
    let deadline = Date().addingTimeInterval(30)
    while quiet < 3, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let now = RenderProbe.counts
        if now == last { quiet += 1 } else { quiet = 0; last = now }
    }
}
