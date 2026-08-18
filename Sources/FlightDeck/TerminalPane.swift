import SwiftUI

/// The container the selected surface is parented into.
///
/// It exists as a subclass for one reason: libghostty has to be *told* the new pixel size or
/// the terminal grid never reflows, and plain `NSView` has no notification for a frame change
/// of its own — upstream drives that from a `SurfaceScrollView` inside the SwiftUI wrapper this
/// app dropped during decoupling. Overriding `setFrameSize` is how this view learns of a resize
/// at all; `onResize` hands the new size to `SessionStore.terminalSizeDidChange(_:)`, which now
/// owns delivering it to `Ghostty.SurfaceView.sizeDidChange(_:)`. Without this hook, nothing
/// would notice the resize, and the Metal layer would stretch over a grid that keeps its
/// launch-time rows and columns.
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
        container.onResize = { [weak store] size in
            store?.terminalSizeDidChange(size)
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
        // carries that old grid — a resize while another tab was selected is enough to produce
        // one. This goes through `activateTerminalSize` rather than `terminalSizeDidChange`
        // because the store's size has not changed; only this surface's copy of it is stale.
        if let id = store.selectedSessionID {
            store.activateTerminalSize(for: id)
        }
        store.tick()
    }
}
