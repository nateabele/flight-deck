import SwiftUI

/// The container the selected surface is parented into.
///
/// It exists as a subclass for one reason: libghostty has to be *told* the new pixel size or
/// the terminal grid never reflows. `Ghostty.SurfaceView.sizeDidChange(_:)` is the call that
/// does that, and upstream drives it from a `SurfaceScrollView` inside the SwiftUI wrapper
/// this app dropped during decoupling — so without this hook nothing calls it at all, and the
/// Metal layer stretches over a grid that keeps its launch-time rows and columns.
final class TerminalHostView: NSView {
    var onResize: ((CGSize) -> Void)?

    /// Set by `TerminalPane` on every update. Non-nil means there is a session here to
    /// close; nil means this view should let `performClose:` continue up to the window.
    var onCloseSession: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }

    /// ⌘W and File ▸ Close mean "close this session", not "close the window".
    ///
    /// Declared rather than overridden: `NSView` does not define `performClose(_:)`, and
    /// responder-chain dispatch is by selector lookup, not by inheritance. There is
    /// correspondingly no `super` to call — declining the action is done by failing
    /// validation below, which makes AppKit keep walking the chain to the window.
    @objc func performClose(_ sender: Any?) {
        onCloseSession?()
    }
}

/// Without this, AppKit would treat this view as the handler for `performClose:` even when
/// there is no session behind it, and ⌘W would silently do nothing instead of closing the
/// window.
extension TerminalHostView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performClose(_:)) else { return true }
        return onCloseSession != nil
    }
}

/// Hosts the Store's currently-selected surface. The surface is retained by the
/// Store, not by this view, so selection changes re-parent the same live NSView
/// (the shell keeps running) instead of recreating it.
struct TerminalPane: NSViewRepresentable {
    @ObservedObject var store: SessionStore

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView()
        container.autoresizingMask = [.width, .height]
        container.onResize = { [weak container] size in
            guard let surface = container?.subviews.first as? Ghostty.SurfaceView else { return }
            Self.report(size, to: surface)
        }
        return container
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        let current = store.selectedSessionID.flatMap { store.surface(for: $0) }

        // Refreshed on every update, not just on attach: `updateNSView` is the only place
        // that learns about a selection change, and a stale capture here would close the
        // previously-selected session.
        container.onCloseSession = store.selectedSessionID.map { id in
            { [weak store] in store?.closeSession(id) }
        }

        // Detach any surface that isn't the current selection. It stays retained
        // by the Store, so its shell keeps running while off-screen.
        for sub in container.subviews where sub !== current {
            sub.removeFromSuperview()
        }

        guard let surface = current else { return }
        if surface.superview !== container {
            surface.frame = container.bounds
            surface.autoresizingMask = [.width, .height]
            container.addSubview(surface)
            Ghostty.moveFocus(to: surface)
        }

        // Unconditionally, not just on attach. Re-parenting is how tab switching works, so a
        // surface that was created off-screen or last shown at a different window size still
        // carries that old grid — resizing the window while another tab is selected is enough
        // to produce one.
        Self.report(container.bounds.size, to: surface)
        store.tick()
    }

    /// A zero-sized container is a normal transient state (added early, or to a hierarchy
    /// that is not on screen yet); upstream Ghostty guards the same call the same way in
    /// `SurfaceScrollView.synchronizeCoreSurface`.
    private static func report(_ size: CGSize, to surface: Ghostty.SurfaceView) {
        guard size.width > 0, size.height > 0 else { return }
        surface.sizeDidChange(size)
    }
}
