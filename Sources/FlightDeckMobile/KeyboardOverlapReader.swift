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
/// expose it, so this installs a hidden, zero-width probe in the window's ROOT VIEW
/// CONTROLLER'S VIEW, pinned from that view's guide top to its bottom. The guide moving changes
/// the probe's height, a height change lays the probe out, and its `layoutSubviews` is the
/// per-frame callback nothing else offers. Not the window's own guide: on an iPhone 15 Pro
/// (iOS 18.3.1) that one never moved — it logged its top at 852, the window's full height,
/// while `keyboardWillChangeFrame` put the keyboard's top at 561 — so the probe was laid out
/// once at launch, the lift stayed 0, and with SwiftUI's avoidance off the keyboard covered
/// the composer. The root view controller's view has a guide UIKit actually drives.
///
/// **Two kinds of report, `settled` and live.** A show, hide or height change is reported
/// once, from `keyboardWillChangeFrame`'s END frame, as `settled` and inside an animation; the
/// interactive drag is reported per frame from the probe, unanimated and not settled. The
/// consumer lays out by the settled value and only OFFSETS by the live one — see
/// `KeyboardLiftedInset` for why applying a per-frame value as layout made the drag jerk.
///
/// Used by `SessionTimelineScreen`, which turns SwiftUI's keyboard avoidance OFF
/// (`.ignoresSafeArea(.keyboard)`) and lifts its composer by this value instead — both halves
/// are needed; with the lift alone, the composer would be lifted twice. **Host it in the
/// smallest view that uses the value** (there, `KeyboardLiftedInset`): it reports at display
/// rate through a drag, and every report re-runs the body of whichever view owns the state.
struct KeyboardOverlapReader: UIViewRepresentable {
    /// Called with the keyboard's `overlap` and whether it is `settled`.
    ///
    /// `settled == true` is the value to lay out by, and it comes from two places. Mostly it is
    /// where a show, hide or height change will END, delivered once per `keyboardWillChangeFrame`
    /// **that arrives while the host is in a window**, inside a `withAnimation` matched to the
    /// keyboard's duration. The other is the probe's FIRST report after the host enters a
    /// window, delivered unanimated: a notification that landed while the screen was out of the
    /// window (a detail row pushed over it) was dropped, and that report is the only thing that
    /// can correct a settled value it left stale. `settled == false` is one frame of an
    /// interactive drag, delivered unanimated — a value to track the finger with, not to lay out
    /// by. A consumer should treat every report as the current position and only a settled one
    /// as the new resting place.
    ///
    /// Drag reports arrive only when the overlap differs from the last one reported. That
    /// equality gate is what keeps this out of a loop: setting SwiftUI state re-renders the
    /// screen, a re-render can lay the view out again, and an unconditional report would answer
    /// every one of those passes with another state write.
    let onChange: (_ overlap: CGFloat, _ settled: Bool) -> Void

    /// The pure half, and the only part a simulator test can reach. With the keyboard down the
    /// guide's top sits at the top of the home-indicator inset, so the probe is exactly that
    /// tall and the lift is zero. With it up, the composer's inset already sits ABOVE the home
    /// indicator, so lifting it by the keyboard's full height would float the field one inset
    /// clear of the keyboard. Clamped at zero so a transient short probe reads as "no keyboard"
    /// rather than pushing the composer down into the home indicator.
    static func overlap(probeHeight: CGFloat, safeBottom: CGFloat) -> CGFloat {
        max(0, probeHeight - safeBottom)
    }

    /// The same lift, from `keyboardWillChangeFrame`'s end frame — already converted into the
    /// window's coordinates — rather than from the probe.
    ///
    /// **Only a DOCKED keyboard lifts anything.** The app ships on iPad, where a floating or
    /// split keyboard ends mid-screen and an undocked one can report `CGRect.zero`. Measured as
    /// "window height minus the frame's top", either reads as a keyboard nearly the height of
    /// the window: the composer thrown off the top of the screen and the `List` padded by a
    /// screen until the next docked event. So a frame counts only if it is non-empty and
    /// reaches the window's bottom edge (within a point, for rounding in the conversion).
    ///
    /// **Only the part inside the window counts.** A Stage Manager window is not at the screen
    /// origin, so a converted keyboard can spill past its sides and bottom; the intersection is
    /// what actually covers the composer. The home-indicator inset is taken off for the same
    /// reason `overlap(probeHeight:safeBottom:)` takes it off.
    static func overlap(keyboardEnd: CGRect, windowBounds: CGRect, safeBottom: CGFloat) -> CGFloat {
        let docked = !keyboardEnd.isEmpty && keyboardEnd.maxY >= windowBounds.maxY - 1
        guard docked else { return 0 }
        let covered = windowBounds.intersection(keyboardEnd)
        return covered.isNull ? 0 : max(0, covered.height - safeBottom)
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
    /// window the screen is in. The probe goes in the root view controller's view rather than
    /// in this view because `keyboardLayoutGuide` is measured against the view that owns it,
    /// and this view sits wherever SwiftUI put the `.background` — the root view fills the
    /// window, so its bottom edge is the same fixed reference the keyboard is measured from.
    /// Not the window itself, whose guide does not track the keyboard at all (see the type's
    /// header for the device evidence).
    final class HostView: UIView {
        var onChange: ((CGFloat, Bool) -> Void)?

        private var probe: ProbeView?
        /// `nil` until the first report in a window, so a screen re-entering a window always
        /// reports once even if the value happens to match what it last saw somewhere else.
        private var lastReported: CGFloat?
        /// Until when the probe's reports are ignored. A show/hide is announced by a
        /// notification that carries the keyboard's own duration and end frame, and is reported
        /// from there, animated. The guide's own layout of that same move lands inside UIKit's
        /// animation block as ONE jump to the final frame; reported too, it would replace the
        /// animated value with an unanimated one and the composer would teleport while the
        /// keyboard slides. A probe report outside this window is the interactive drag, which
        /// must be applied unanimated so the field tracks the finger 1:1.
        private var animateUntil: CFTimeInterval = 0
        /// Whether the probe's next report is the first since the host entered a window, and so
        /// must be reported SETTLED. Notifications are dropped while the host has no window;
        /// push a detail row with the keyboard up and the hide lands while the timeline is off
        /// screen. On the pop, a merely live report would correct `live` alone and leave
        /// `settled` at the keyboard's height — the last message floating over a blank gap.
        private var needsSettle = false

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
            // a runloop turn after the notification, and missing the window by a frame would let
            // that one-jump report through, unanimated, turning a slide into a snap.
            animateUntil = CACurrentMediaTime() + max(duration, 0.25) + 0.1
            // The notification carries where the keyboard will END, which is the settled value
            // — reported from here rather than from the probe, because the probe cannot be
            // trusted to report it: after a drag that already carried the keyboard to the
            // bottom, the guide does not move again, the probe is not laid out again, and a
            // composer whose layout was still reserving the keyboard's height would be stranded
            // above an empty gap.
            if let window, let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue)?.cgRectValue {
                let overlap = KeyboardOverlapReader.overlap(
                    keyboardEnd: window.convert(end, from: window.screen.coordinateSpace),
                    windowBounds: window.bounds,
                    safeBottom: window.safeAreaInsets.bottom)
                lastReported = overlap
                // This notification settled the value itself, so the probe's first report no
                // longer has a missed one to make up for — and landing mid-animation, it would
                // cut this animated move short.
                needsSettle = false
                guard let onChange else { return }
                // A spring close to the keyboard's own curve, which SwiftUI cannot be handed
                // directly — the notification's curve is a private `UIView.AnimationCurve` (7).
                withAnimation(.spring(duration: max(duration, 0.25), bounce: 0)) {
                    onChange(overlap, true)
                }
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Removed whenever the host leaves a window, so a popped screen does not leave an
            // orphan probe behind in the window reporting into state nothing reads — and a
            // screen pushed again installs a fresh one rather than stacking a second.
            probe?.removeFromSuperview()
            probe = nil
            lastReported = nil
            needsSettle = window != nil
            guard let window else { return }

            let probe = ProbeView()
            probe.isHidden = true
            probe.isUserInteractionEnabled = false
            probe.translatesAutoresizingMaskIntoConstraints = false
            // The root view controller's view, not the window: the window's guide sat at the
            // window's full height with the keyboard up, so a probe pinned to it never resized
            // and the composer was left under the keyboard. The window is only a fallback for a
            // window with no root view controller, which a SwiftUI scene never produces.
            let container: UIView = window.rootViewController?.view ?? window
            container.addSubview(probe)
            NSLayoutConstraint.activate([
                probe.topAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor),
                probe.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                probe.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                probe.widthAnchor.constraint(equalToConstant: 0),
            ])
            probe.onLayout = { [weak self, weak window] height in
                guard let self, let window else { return }
                self.report(KeyboardOverlapReader.overlap(
                    probeHeight: height, safeBottom: window.safeAreaInsets.bottom))
            }
            self.probe = probe
        }

        /// The probe's per-frame value, which is only ever the interactive drag: a show or hide
        /// is reported from `keyboardWillChangeFrame` with its settled target, and the probe's
        /// own report of that same move — one jump inside UIKit's animation block — is ignored
        /// until the animation window closes, or it would cut the animated move short.
        ///
        /// The exception is the first report after entering a window (`needsSettle`), which
        /// goes out settled and ahead of the `animateUntil` gate: an animation window opened by
        /// a notification the host was not there to apply must not swallow the one report that
        /// re-syncs it.
        private func report(_ overlap: CGFloat) {
            if needsSettle {
                needsSettle = false
                lastReported = overlap
                onChange?(overlap, true)
                return
            }
            guard CACurrentMediaTime() >= animateUntil else { return }
            guard overlap != lastReported else { return }
            lastReported = overlap
            onChange?(overlap, false)
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
