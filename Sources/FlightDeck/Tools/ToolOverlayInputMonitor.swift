import AppKit

/// Feeds mouse movement and keystrokes to `ToolOverlayModel`.
///
/// **Shaped after `SidebarInputMonitor`, including its scoping discipline.** One passive local
/// monitor that never consumes an event, so terminal input, hit-testing and list dragging
/// cannot change. `NSEvent.addLocalMonitorForEvents` sees every event in the process, so it
/// must prove what it is looking at before acting.
///
/// **Why mouse movement is available at all.** macOS only generates `mouseMoved` when
/// something asks for it. `Ghostty.SurfaceView.updateTrackingAreas` installs an
/// `NSTrackingArea` with `.mouseMoved`, so those events flow over the terminal. If a future
/// re-pull of the adapt-copied Ghostty drops that flag, fade-in stops working and nothing here
/// will say so — see the design doc's risk list.
///
/// **Why the qualification is a hit-test walk rather than a frame check.** It needs no geometry
/// plumbed out of SwiftUI, and it naturally excludes the sidebar: crossing it must not fade the
/// buttons in. Hovering the cluster itself hit-tests to the SwiftUI host rather than
/// `TerminalHostView`, which is why pinning goes through `.onHover` on the view instead.
@MainActor
final class ToolOverlayInputMonitor {
    private var mouseToken: Any?
    private var keyToken: Any?
    private weak var host: NSWindow?

    var onMouseMovedOverTerminal: (() -> Void)?
    var onKeyPressed: (() -> Void)?

    func start() {
        captureHostWindow()

        if mouseToken == nil {
            mouseToken = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.handleMouseMoved(event)
                return event   // never consumed
            }
        }
        if keyToken == nil {
            keyToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = event.window, window === self.host else { return event }
                self.onKeyPressed?()
                return event   // never consumed
            }
        }
    }

    func stop() {
        if let mouseToken { NSEvent.removeMonitor(mouseToken) }
        if let keyToken { NSEvent.removeMonitor(keyToken) }
        mouseToken = nil
        keyToken = nil
        host = nil
    }

    deinit {
        // Hop to the main actor rather than removing inline, matching `SidebarInputMonitor`:
        // `removeMonitor` is an AppKit call and belongs on the main thread.
        let (mouse, key) = (mouseToken, keyToken)
        if mouse != nil || key != nil {
            DispatchQueue.main.async {
                if let mouse { NSEvent.removeMonitor(mouse) }
                if let key { NSEvent.removeMonitor(key) }
            }
        }
    }

    /// SwiftUI's `onAppear` can run before the view is in a window, so this retries briefly.
    private func captureHostWindow(attempt: Int = 0) {
        guard host == nil else { return }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            host = window
            return
        }
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.captureHostWindow(attempt: attempt + 1)
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard let window = event.window, window === host, let content = window.contentView else { return }
        // `NSView.hitTest(_:)` takes a point in the receiver's SUPERVIEW coordinates; for a
        // window's `contentView` that is already `locationInWindow`, so no conversion.
        guard let hit = content.hitTest(event.locationInWindow) else { return }
        guard Self.isOverTerminal(hit) else { return }
        onMouseMovedOverTerminal?()
    }

    /// Read-only walk: nothing is attached, replaced or reconfigured.
    private static func isOverTerminal(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is TerminalHostView { return true }
            candidate = current.superview
        }
        return false
    }
}

/// `@StateObject` needs an `ObservableObject`; the monitor publishes nothing, so it is held in
/// a box rather than made observable — an observable monitor would invalidate the view on
/// every mouse move, which is the opposite of what this feature wants.
@MainActor
final class ToolOverlayInputMonitorBox: ObservableObject {
    let monitor = ToolOverlayInputMonitor()
}
