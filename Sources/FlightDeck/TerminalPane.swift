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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
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
