// Sources/FlightDeck/ScreenLock.swift
import CoreGraphics
import Foundation

/// Whether this login session's screen is locked.
///
/// Injected as a protocol for the same reason `ProcessInspecting` is: the answer is a
/// property of the machine running the suite, so a test that needs the other value has no
/// way to get one.
///
/// This exists because of a real failure. `Ghostty.SurfaceView` creation needs the window
/// server, and a locked session has none — so a tab created from the phone while the Mac was
/// locked got no terminal, no agent, and no error. See
/// `docs/superpowers/specs/2026-08-29-diagnostics-query-interface-design.md` §1.
protocol ScreenLockInspecting: Sendable {
    var isLocked: Bool { get }
}

struct ScreenLock: ScreenLockInspecting {
    /// `CGSessionCopyCurrentDictionary` rather than a `loginwindow` notification: this is a
    /// question asked at one instant, by a caller that is about to decide whether to create a
    /// surface, not a state worth observing continuously. A nil dictionary means there is no
    /// GUI session at all (a headless test host), which is at least as unable to make a
    /// surface as a locked one — so it reads as locked rather than as unknown.
    var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
