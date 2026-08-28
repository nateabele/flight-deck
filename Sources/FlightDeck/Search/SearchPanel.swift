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
/// **Why a child window.** Added to the deck window with `addChildWindow(_:ordered:)`, so it
/// tracks the host's moves, resizes and miniaturisation without observing anything.
@MainActor
final class SearchPanel: NSPanel {
    private let model: SearchModel
    private weak var host: NSWindow?

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
        // Closing the deck window must take this with it rather than leaving an orphan
        // floating over other apps.
        hidesOnDeactivate = true

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
        self.host = host
        setFrame(host.frame, display: false)
        host.addChildWindow(self, ordered: .above)
        model.open()
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        model.close()
        host?.removeChildWindow(self)
        orderOut(nil)
        // Focus has to go back to the terminal explicitly. Ordering out a key child window
        // leaves the host key but leaves first responder unset, so the next keystroke would
        // go nowhere.
        host?.makeKeyAndOrderFront(nil)
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
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.18)
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
