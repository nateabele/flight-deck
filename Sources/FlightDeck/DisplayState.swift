// Sources/FlightDeck/DisplayState.swift
import CoreGraphics
import Foundation

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
