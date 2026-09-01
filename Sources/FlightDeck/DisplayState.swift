// Sources/FlightDeck/DisplayState.swift
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Whether the main display can currently be drawn to.
///
/// Injected as a protocol for the same reason `ProcessInspecting` is: the answer is a property
/// of the machine running the suite, so a test that needs the other value has no way to get one.
///
/// **This is the precondition for creating a terminal, and it is not about the screen lock.**
/// Established by controlled trial (spec §1.1): with the display asleep libghostty returns a
/// `SurfaceView` but never forks a shell, so the tab is inert from birth — no `login`, no
/// `claude`, no status file. Lock merely correlates, because it usually precedes display sleep;
/// a tab created 19s after lock with the display still on came up healthy.
///
/// CoreGraphics says why, in its own header: `CGDisplayIsActive` means "connected, awake, and
/// available for **drawing**", and `CGDisplayIsAsleep` is true when the display is asleep "and
/// is therefore **not drawable**". libghostty needs that drawable.
protocol DisplayInspecting: Sendable {
    var isDrawable: Bool { get }
}

struct DisplayState: DisplayInspecting {
    /// `CGDisplayIsActive` rather than `!CGDisplayIsAsleep`: they are not complements. A
    /// display that is off, disconnected, or in mirroring teardown is inactive without being
    /// asleep, and every one of those is equally unable to back a surface. Active is the
    /// narrower, safer question for a caller about to decide whether creation can succeed.
    ///
    /// `boolean_t` is a `UInt32`, hence the explicit comparison.
    var isDrawable: Bool { CGDisplayIsActive(CGMainDisplayID()) != 0 }
}

/// `SessionStore.display`'s default, deliberately permissive rather than deliberately real —
/// the opposite choice from `processInspector`, which defaults to the real `ProcessTree()`.
/// `ProcessTree` is a deterministic query that never gates control flow, so a real default
/// there costs nothing. `display` gates whether creation is allowed to proceed at all, and its
/// answer depends on whether a monitor happens to be awake on the machine running the code —
/// something almost no test intends to depend on, and the one place that did depend on it
/// (`CodexLaunchFailureTests.testClosingTheLastTabDoesNotKillAnAppServerACreationIsStillUsing`)
/// didn't fail when the display went to sleep, it **hung**, because the guard's `.failure`
/// returns before `GatedAdapter.prepare()` ever runs. A permissive default means every one of
/// the 23 test files (75 call sites) that construct a `SessionStore` with a real provider gets
/// a working terminal without asking for one, and the guard is only exercised by tests that
/// inject `DisplayState()` (or another false-returning stub) on purpose — see
/// `DisplayDrawableGuardTests`.
///
/// **This is the load-bearing seam for the whole feature.** `SessionStore`'s `convenience
/// init(ghostty:...)` — the one production code actually calls — assigns the real
/// `DisplayState()` immediately after `self.init(provider:...)`, before `seedInitialSession()`
/// runs; that one line is what makes the guard mean anything in production. Remove it and
/// `canCreateTerminal` is unconditionally `true` again — the original bug (an inert tab with
/// no shell, silently persisted and broadcast) returns, and no test will notice, because every
/// test that would have caught it also stopped injecting the real probe. `DisplayDrawableGuardTests
/// .testTheRealProbeIsWiredIn` is the one test that exists specifically to catch that deletion.
struct AlwaysDrawableDisplay: DisplayInspecting {
    var isDrawable: Bool { true }
}

/// Asks a sleeping display to wake, and waits for it to become drawable.
///
/// Separate from `DisplayInspecting` because the two answer different questions and only one
/// of them has a side effect: `isDrawable` is a cheap pure query that `canCreateTerminal`
/// leans on, and lighting up the user's screen must never be something a property getter can
/// do by accident.
protocol DisplayWaking: Sendable {
    /// Wake the display if needed and block until it is drawable. Returns whether it is.
    func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool
}

/// The real one.
///
/// **The wake is asynchronous, which is the whole reason this type exists.** Measured on
/// 2026-08-31: `IOPMAssertionDeclareUserActivity` returns at once, but `CGDisplayIsActive`
/// only goes true 0.173-0.342s later (n=4, locked Mac). Declaring activity and proceeding
/// straight to `ghostty_surface_new` would therefore still find no drawable and still fork
/// nothing — the exact bug this is meant to fix, arriving 200ms later. So: declare, then poll.
///
/// **One declaration is enough and nothing needs releasing.** The display stayed active for
/// at least 3s after a single call, which is ample to fork a shell. This deliberately does
/// not hold an assertion open: the screen should go back to sleep on its own schedule.
struct DisplayWaker: DisplayWaking {
    /// The probe to poll. Injected so the polling and timeout logic is testable without a
    /// display; the IOKit call below is the only part that cannot be.
    var display: DisplayInspecting = DisplayState()
    /// 25ms against a 173-342ms wake is 7-14 samples across the expected range.
    var pollInterval: TimeInterval = 0.025
    var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Injected so no test can wake the machine running the suite.
    var declareUserActivity: @Sendable () -> Void = DisplayWaker.declareLocalUserActivity

    /// `kIOPMUserActiveLocal` — activity at *this* machine, which is what wakes its display.
    ///
    /// The return code is deliberately discarded. A failed assertion does not prove the
    /// display is un-drawable (something else may be waking it), and the poll below is a
    /// direct observation, which beats an inference either way.
    static func declareLocalUserActivity() {
        var assertion: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity(
            "Flight Deck is opening a terminal" as CFString, kIOPMUserActiveLocal, &assertion
        )
    }

    func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool {
        // Checked first so the common case — every creation on a Mac someone is looking at —
        // costs one `CGDisplayIsActive` call and never sleeps.
        if display.isDrawable { return true }
        declareUserActivity()
        // A deadline, not an accumulated total of the requested interval: `sleep` overshoots
        // every call, so summing `pollInterval` drifts past `timeout` with no ceiling. This is
        // the wall clock the 1.5s keepalive-headroom argument actually needs.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            sleep(pollInterval)
            if display.isDrawable { return true }
        }
        return false
    }
}

/// `SessionStore.displayWaker`'s default: never wakes, never blocks, always reports failure.
///
/// Inert for the same reason `AlwaysDrawableDisplay` is permissive — the suite must not
/// depend on the machine running it. Here the stakes are higher than a wrong answer: a real
/// `DisplayWaker` in a test would physically wake the developer's screen, once per call.
struct NeverWakingDisplay: DisplayWaking {
    func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool { false }
}
