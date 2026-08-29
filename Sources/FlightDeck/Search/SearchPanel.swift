import AppKit
import SwiftUI

/// The window the overlay lives in.
///
/// **Why a panel rather than a SwiftUI overlay in `RootView`.** `Ghostty.SurfaceView`
/// returns true from `performKeyEquivalent(with:)` for anything libghostty binds, and
/// libghostty binds most ⌘-chords — so an in-window overlay would be contending with the
/// terminal for every keystroke, including the arrow keys and Return this needs. A panel
/// that becomes key takes first-responder status off the surface entirely, and the text
/// field simply has focus.
///
/// **Why a child window.** Added to the deck window with `addChildWindow(_:ordered:)`, which
/// synchronises this panel's moves, ordering and miniaturisation with the host automatically.
/// Resize is NOT part of that — AppKit does not resize a child window when its parent
/// resizes — so `present(over:)` observes the host's resize explicitly and re-applies its
/// frame; without that, resizing the deck window while the overlay is open would leave the
/// scrim not covering the window and the card (positioned as a fraction of the panel's own
/// geometry) drifting off it.
@MainActor
final class SearchPanel: NSPanel {
    private let model: SearchModel
    private weak var host: NSWindow?
    private var keyMonitor: Any?
    /// Guards `present`/`dismiss` against being called out of turn: a second `present` before
    /// a matching `dismiss` would re-register this panel as the host's child window, and Esc
    /// can reach `dismiss` twice for one keypress (`cancelOperation` and SwiftUI's
    /// `.onExitCommand` can both fire, depending on where first responder lands), which
    /// without this would repeat the whole teardown for no reason.
    private var isPresented = false
    private var resizeObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?

    init(model: SearchModel, onActivate: @escaping (SearchResult) -> Void) {
        self.model = model
        super.init(
            contentRect: .zero,
            // `.nonactivatingPanel` is deliberately absent: this panel must become key so
            // the terminal stops receiving keys while it is up.
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // the card draws its own; the scrim must not have one
        level = .floating
        isMovable = false
        // `NSPanel` defaults `hidesOnDeactivate` to `true` (unlike `NSWindow`, which
        // defaults it to `false`), so it must be turned off explicitly here. Left at the
        // default, AppKit would hide the panel behind our back on app deactivation while
        // `model` still believes it is open and `host` still holds it as a child window —
        // so the next ⌘K would call `present(over:)` on an already-parented panel — and
        // AppKit re-orders a hidden-on-deactivate window to the front on reactivation,
        // which would raise the panel over whatever app the user switched to. Routing
        // deactivation through the explicit observer below and `dismiss()` instead keeps
        // this the single teardown path every other exit uses, so the model, the host's
        // child-window list and the screen can never disagree about whether it is open.
        hidesOnDeactivate = false

        let root = SearchOverlayRoot(
            model: model,
            onActivate: { [weak self] result in self?.dismiss(); onActivate(result) },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        contentView = NSHostingView(rootView: root)
    }

    /// Key and main, or the text field cannot take focus while a terminal is running.
    override var canBecomeKey: Bool { true }

    func present(over host: NSWindow) {
        // Without this, a stray second call before a matching `dismiss` would call
        // `host.addChildWindow` on this panel twice, corrupting the host's child-window list.
        guard !isPresented else { return }
        isPresented = true
        self.host = host
        setFrame(host.frame, display: false)
        host.addChildWindow(self, ordered: .above)
        startKeyMonitor(model: model)
        model.open()
        makeKeyAndOrderFront(nil)

        // `addChildWindow` does not keep this panel's frame in sync with the host's — see the
        // class doc. Re-applies the host's frame on every resize while presented.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: host, queue: .main
        ) { [weak self] _ in
            guard let self, let host = self.host else { return }
            self.setFrame(host.frame, display: true)
        }

        // See the `hidesOnDeactivate` comment in `init` for why this dismisses outright
        // rather than merely hiding. `restoringFocus: false` — see `dismiss(restoringFocus:)`
        // — because the whole app is going away here, not just this panel.
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismiss(restoringFocus: false) }
    }

    /// Esc, the scrim, and activating a result all restore focus to the terminal — this is
    /// the only public entry point, and it always does.
    func dismiss() { dismiss(restoringFocus: true) }

    /// - Parameter restoringFocus: Whether to hand first responder back to the host. `true`
    ///   for every ordinary dismissal: ordering out a key child window leaves the host key but
    ///   first responder unset, so without this the terminal would go deaf to the next
    ///   keystroke. `false` only from the deactivation path in `present(over:)` — there the
    ///   app itself is resigning active, `makeKeyAndOrderFront:` cannot make a window key for
    ///   an inactive app, but `orderFront:`'s half still runs and can raise the host window at
    ///   the window-server level (shared across applications), which would make the deck
    ///   window jump in front of whatever app the user just switched to.
    private func dismiss(restoringFocus: Bool) {
        guard isPresented else { return }
        isPresented = false
        // Symmetric with what `present(over:)` adds: an observation left running past
        // dismissal would keep reacting to a host the panel is no longer attached to.
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        resizeObserver = nil
        deactivationObserver = nil

        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.close()
        host?.removeChildWindow(self)
        orderOut(nil)
        if restoringFocus {
            host?.makeKeyAndOrderFront(nil)
        }
    }

    /// Up and down move the highlight while the query field keeps focus.
    ///
    /// SwiftUI's `.onMoveCommand` never fires here: the panel's first responder is the search
    /// field, and the field consumes the arrow keys as text navigation before any enclosing view
    /// sees them — so the list could not be arrowed through at all. A local monitor sits ahead of
    /// the responder chain and claims exactly the two keycodes, returning nil so the field never
    /// receives them, and passes everything else through untouched.
    ///
    /// Local, not global: it only sees this process's events and needs no accessibility
    /// permission. Installed on present and removed on dismiss, so a dismissed panel is not still
    /// eating arrow keys the terminal wants.
    private func startKeyMonitor(model: SearchModel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: model.moveSelection(by: -1); return nil   // up arrow
            case 125: model.moveSelection(by: 1); return nil    // down arrow
            default: return event
            }
        }
    }

    /// Esc closes. Handled here rather than with `.keyboardShortcut(.cancelAction)` because
    /// the panel has no default button for SwiftUI to attach that to.
    override func cancelOperation(_ sender: Any?) { dismiss() }
}

/// Scrim plus card. Separated from `SearchOverlayView` so the dimming and the arrow-key
/// handling live with the window rather than with the list.
private struct SearchOverlayRoot: View {
    @ObservedObject var model: SearchModel
    var onActivate: (SearchResult) -> Void
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            GeometryReader { geometry in
                SearchOverlayView(model: model, onActivate: onActivate, onDismiss: onDismiss)
                    // Top-anchored, NOT `.position`. `.position` places a view's CENTRE at the
                    // given point, so as the card grew with the result count its top climbed
                    // past the window and clipped — the query field itself could go off screen,
                    // which is the one part that must never be hidden. Offsetting a
                    // top-aligned frame instead pins the top edge and lets the card grow
                    // downward, and `min` keeps it on screen when the window is short enough
                    // that even 18% would push the bottom off.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, min(geometry.size.height * 0.18,
                                       max(0, geometry.size.height - 120)))
            }
        }
        // Arrow keys move the highlight. `onMoveCommand` rather than a key monitor: it is
        // scoped to this view's focus, so it cannot intercept anything once the panel is down.
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSelection(by: -1)
            case .down: model.moveSelection(by: 1)
            default: break
            }
        }
        .onExitCommand { onDismiss() }
    }
}
