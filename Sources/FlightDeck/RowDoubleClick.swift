import AppKit
import SwiftUI

// Double-click-to-rename on a sidebar row without eating the mouse-down that `List`'s
// `.onMove` needs to start a drag.
//
// Root cause, from the macOS SDK headers (this is the evidence, not a guess):
//
//   NSGestureRecognizer.h:65-67
//   > "causes the specified events to be delivered to the target view only after this
//   > gesture has failed recognition… refer to specific gesture subclasses as they have
//   > different defaults."
//   > `@property BOOL delaysPrimaryMouseButtonEvents; // default is NO.`
//
//   NSClickGestureRecognizer.h:19-21
//   > "NSClickGestureRecognizer dynamically returns YES to delay primary, secondary and
//   > other mouse events depending on this value [buttonMask]."
//
// `NSGestureRecognizer` passes the mouse-down straight through by default, but
// `NSClickGestureRecognizer` overrides that and withholds it until the click either
// recognizes or fails. `List`'s reorder is AppKit-level and needs that mouse-down
// immediately, so the drag never starts. SwiftUI's `.onTapGesture` is built on this same
// recognizer and exposes no way to reach the property — `.onTapGesture` and
// `.simultaneousGesture` both failed on this row for the same underlying reason; they were
// the same mechanism twice. See `SessionSidebar.swift:26-38` for where that was measured
// and ripped out.
//
// This file defeats it directly: a recognizer subclass that hard-codes
// `delaysPrimaryMouseButtonEvents = false`, attached to an ancestor view rather than to
// anything SwiftUI treats as part of the row's hit-testing.

/// `NSClickGestureRecognizer` that never withholds the primary mouse-down.
///
/// The base class computes `delaysPrimaryMouseButtonEvents` dynamically from its
/// `buttonMask` (see the header quote above) — that computed answer is exactly what breaks
/// drag-to-reorder. Overriding the getter to always return `false` defeats that computation
/// instead of relying on any documented way to disable it, because there isn't one.
final class NonDelayingDoubleClickRecognizer: NSClickGestureRecognizer {
    override var delaysPrimaryMouseButtonEvents: Bool {
        get { false }
        set { /* Ignored: the whole point is that this is never allowed to become true. */ }
    }

    init(target: AnyObject, action: Selector) {
        super.init(target: target, action: action)
        numberOfClicksRequired = 2
        buttonMask = 0x1  // primary button only
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A zero-footprint `NSView` that attaches a double-click recognizer to an ancestor,
/// never to itself.
///
/// A previous attempt put a real `NSView` in `.background()` and it took over the row's
/// hit-test geometry, making the title unhittable — 6 of 6 UI test runs failed with
/// `"Not hittable: StaticText … session-row-title"` (quoted in full at
/// `SessionSidebar.swift:84-90`). Two rules keep this view from repeating that:
///
/// 1. `hitTest(_:)` always returns `nil`, so this view never participates in
///    hit-testing and cannot steal anything, no matter what SwiftUI does with its frame.
/// 2. Because it can never be hit, it can never see the click itself, so the recognizer
///    is attached to an ancestor instead — nearest `NSTableRowView`, falling back to the
///    enclosing `NSTableView`, falling back to `superview`. That ancestor spans the whole
///    row and IS hit when the title is clicked, so the recognizer sees the event while this
///    view stays invisible.
private final class DoubleClickCatcherView: NSView {
    var action: (() -> Void)?

    private weak var attachedAncestor: NSView?
    private weak var recognizer: NonDelayingDoubleClickRecognizer?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            detach()
            return
        }
        attachIfNeeded()
    }

    private func attachIfNeeded() {
        guard recognizer == nil else { return }
        guard let ancestor = findAncestor() else {
            // SwiftUI can call `viewDidMoveToWindow()` before it has finished building the
            // `NSTableRowView`/`NSTableView` chain for this row, so the walk below can come
            // up empty on the first pass. Retry once on the next runloop tick, by which
            // point layout has normally caught up; if it still hasn't, fall back to
            // `superview` rather than leaving the row permanently un-clickable.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.recognizer == nil else { return }
                if let ancestor = self.findAncestor() ?? self.superview {
                    self.attach(to: ancestor)
                }
            }
            return
        }
        attach(to: ancestor)
    }

    /// Nearest `NSTableRowView`, else the enclosing `NSTableView`, else `superview`.
    private func findAncestor() -> NSView? {
        var view: NSView? = superview
        while let candidate = view {
            if candidate is NSTableRowView { return candidate }
            if candidate is NSTableView { return candidate }
            view = candidate.superview
        }
        return nil
    }

    private func attach(to ancestor: NSView) {
        // Rows are reused by SwiftUI/AppKit, and `viewDidMoveToWindow()` can fire more than
        // once for the same view. Never leave a stale recognizer behind on an ancestor —
        // detach whatever we previously attached before attaching again.
        detach()
        let recognizer = NonDelayingDoubleClickRecognizer(
            target: self,
            action: #selector(handleDoubleClick)
        )
        ancestor.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
        attachedAncestor = ancestor
    }

    private func detach() {
        if let recognizer, let attachedAncestor {
            attachedAncestor.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        attachedAncestor = nil
    }

    @objc private func handleDoubleClick() {
        action?()
    }
}

/// `NSViewRepresentable` wrapper around `DoubleClickCatcherView`. See the file-level
/// comment and `DoubleClickCatcherView` for why this exists and why it is safe to place in
/// a SwiftUI `.background()`.
private struct RowDoubleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> DoubleClickCatcherView {
        let view = DoubleClickCatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: DoubleClickCatcherView, context: Context) {
        // The closure is rebound on every update rather than captured once at creation, so
        // a double-click can never fire a closure from a previous, now-stale render.
        nsView.action = action
    }
}

extension View {
    /// Fires `action` on a double-click anywhere within this view's row, without consuming
    /// the primary mouse-down that `List`'s drag-to-reorder needs. See the comment at the
    /// top of `RowDoubleClick.swift` for why a plain `.onTapGesture(count: 2)` cannot do
    /// this.
    func onRowDoubleClick(perform action: @escaping () -> Void) -> some View {
        background(RowDoubleClickCatcher(action: action))
    }
}
