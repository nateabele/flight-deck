#if canImport(AppKit)
import HostKit

// STUB, deleted at the C8 integration merge. Track W2 (`c8-svc`) owns the real
// `Sources/HostDaemon/ScreenPanel.swift`, the floating "UI tests running — don't touch" panel.
// It exists only so `main.swift`'s wiring to the screen lease compiles before W2 merges.
@MainActor
enum ScreenPanel {
    static func show(holder: LeaseHolder) {}
    static func hide() {}
}
#endif
