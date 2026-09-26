import SwiftUI
import UIKit

/// How far the keyboard reaches above the bottom safe area, reported on **every frame** of an
/// interactive dismissal rather than only when the keyboard finishes moving.
///
/// **Why SwiftUI's own keyboard avoidance cannot do this.** SwiftUI lifts a bottom
/// `safeAreaInset` by its *keyboard safe area*, and that value only moves when UIKit posts
/// `keyboardWillShow`/`keyboardWillHide`. A drag started by `.scrollDismissesKeyboard(.interactively)`
/// posts nothing until the finger lifts, so the keyboard follows the finger while the composer
/// sits still above a widening gap, then snaps down in one jump at the end — the defect this
/// exists to remove. Messages keeps its field glued to the keyboard's top edge the whole way.
///
/// **What does track the drag is `keyboardLayoutGuide`**, which UIKit built for exactly this:
/// its top anchor follows the keyboard frame through an interactive dismissal. SwiftUI does not
/// expose it, so this installs a hidden, zero-width probe in the window pinned from the guide's
/// top to the window's bottom. The guide moving changes the probe's height, a height change
/// lays the probe out, and its `layoutSubviews` is the per-frame callback nothing else offers.
///
/// Used by `SessionTimelineScreen`, which turns SwiftUI's keyboard avoidance OFF
/// (`.ignoresSafeArea(.keyboard)`) and pads its composer by this value instead — both halves
/// are needed; with only this one, the composer would be lifted twice.
struct KeyboardOverlapReader: UIViewRepresentable {
    /// Called with the new overlap, only when it differs from the last one reported. The
    /// equality gate is what keeps this out of a loop: setting SwiftUI state re-renders the
    /// screen, a re-render can lay the window out again, and an unconditional report would
    /// answer every one of those passes with another state write.
    let onChange: (CGFloat) -> Void

    /// The pure half, and the only part a simulator test can reach. With the keyboard down the
    /// guide's top sits at the top of the home-indicator inset, so the probe is exactly that
    /// tall and the lift is zero. With it up, the composer's inset already sits ABOVE the home
    /// indicator, so lifting it by the keyboard's full height would float the field one inset
    /// clear of the keyboard. Clamped at zero so a transient short probe reads as "no keyboard"
    /// rather than pushing the composer down into the home indicator.
    static func overlap(probeHeight: CGFloat, safeBottom: CGFloat) -> CGFloat {
        max(0, probeHeight - safeBottom)
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.onChange = onChange
    }

    /// The representable's own view: zero-size, invisible, and only there to learn which
    /// window the screen is in. The probe goes in the WINDOW rather than in this view because
    /// `keyboardLayoutGuide` is measured against the view that owns it, and this view sits
    /// wherever SwiftUI put the `.background` — the window's bottom edge is the one fixed
    /// reference the keyboard is also measured from.
    final class HostView: UIView {
        var onChange: ((CGFloat) -> Void)?

        private var probe: ProbeView?
        /// `nil` until the first report in a window, so a screen re-entering a window always
        /// reports once even if the value happens to match what it last saw somewhere else.
        private var lastReported: CGFloat?
        /// Until when a report should animate. A show/hide is announced by a notification that
        /// carries the keyboard's own duration; the guide's layout lands inside UIKit's
        /// animation block as ONE jump to the final frame, and SwiftUI has to be told to
        /// animate that jump or the composer teleports while the keyboard slides. A report
        /// outside this window is the interactive drag, which must be applied unanimated so the
        /// field tracks the finger 1:1 instead of trailing it on a spring.
        private var animateUntil: CFTimeInterval = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
            // `WillChangeFrame` rather than show/hide: it covers both, plus the height change
            // of a keyboard switching to emoji or a predictive bar appearing, each of which
            // also moves the guide in one animated step.
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func keyboardWillChangeFrame(_ note: Notification) {
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                as? NSNumber)?.doubleValue ?? 0.25
            // A little slack past the keyboard's own duration: the guide's layout pass can land
            // a runloop turn after the notification, and missing the window by a frame would
            // turn a slide into a snap.
            animateUntil = CACurrentMediaTime() + max(duration, 0.25) + 0.1
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Removed whenever the host leaves a window, so a popped screen does not leave an
            // orphan probe behind in the window reporting into state nothing reads — and a
            // screen pushed again installs a fresh one rather than stacking a second.
            probe?.removeFromSuperview()
            probe = nil
            lastReported = nil
            guard let window else { return }

            let probe = ProbeView()
            probe.isHidden = true
            probe.isUserInteractionEnabled = false
            probe.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(probe)
            NSLayoutConstraint.activate([
                probe.topAnchor.constraint(equalTo: window.keyboardLayoutGuide.topAnchor),
                probe.bottomAnchor.constraint(equalTo: window.bottomAnchor),
                probe.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                probe.widthAnchor.constraint(equalToConstant: 0),
            ])
            probe.onLayout = { [weak self, weak window] height in
                guard let self, let window else { return }
                self.report(KeyboardOverlapReader.overlap(
                    probeHeight: height, safeBottom: window.safeAreaInsets.bottom))
            }
            self.probe = probe
        }

        private func report(_ overlap: CGFloat) {
            guard overlap != lastReported else { return }
            lastReported = overlap
            guard let onChange else { return }
            if CACurrentMediaTime() < animateUntil {
                // Close to the keyboard's own curve, which SwiftUI cannot be handed directly —
                // the notification's curve is a private `UIView.AnimationCurve` value (7).
                withAnimation(.spring(duration: 0.35, bounce: 0)) { onChange(overlap) }
            } else {
                onChange(overlap)
            }
        }
    }

    /// The probe itself. Its only job is to say how tall it was just made.
    final class ProbeView: UIView {
        var onLayout: ((CGFloat) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(bounds.height)
        }
    }
}
