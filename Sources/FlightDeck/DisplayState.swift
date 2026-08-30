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
