import FleetKit
import Foundation

/// What one open window consists of: the QR's payload and the short code, minted together.
///
/// One value rather than two returns, because they are one fact — the same window, presented
/// two ways — and a sheet that received them separately could draw a code from one window
/// beside a QR from another.
///
/// `Identifiable` on the slot so `DevicesSettingsTab` can drive its `.sheet(item:)` from the
/// window itself. See that call site for why `.sheet(item:)` and not `.sheet(isPresented:)`.
struct ArmedPairing: Identifiable {
    let payload: PairingPayload
    let code: PairingCode

    var id: UUID { payload.key.slot }
}

/// The pairing window: one provisional slot at a time, expiring on its own, claimable once.
///
/// A pure state machine over an injected clock, so the three rules that constitute the
/// authorization model are assertable without a listener, a camera or a timer. The UI's job
/// is to call `arm`, show the payload, and stop — it holds no policy.
@MainActor
final class PairingArmer {
    /// Long enough to walk to the phone and open the app; short enough that a QR left on a
    /// screen stops being a key almost immediately.
    static let window: TimeInterval = 120

    private let now: () -> Date
    /// Assigned in exactly two places: `arm()` opens a window, `clearPending()` closes one.
    /// Nothing else may write it, which is what makes `onWindowClosed` a guarantee rather
    /// than a convention — see that property.
    private(set) var pending: PairedDevice?

    /// Fired whenever `pending` stops being a live window, by any route — cancelled, claimed
    /// or expired — and from the single place that clears it, so a route added later gets
    /// this without anybody remembering to give it to them.
    ///
    /// It exists because the window's *listener* is not this type's to own but its lifetime
    /// is: `FleetService` hangs `closePairingListener()` off this, which is the rule
    /// "the pairing listener's lifetime is `armer.pending`'s lifetime" made mechanical. The
    /// enumerated alternative — a `closePairingListener()` beside every clear — is what shipped
    /// first, and it missed the QR path, because that route clears `pending` from inside an
    /// `if` whose *second* condition can fail independently.
    var onWindowClosed: (() -> Void)?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The armer's own notion of "now" — exposed so `FleetService.scheduleExpiry` can sleep
    /// for the right number of *real* seconds even when this armer is running on a test's
    /// injected clock. Computing that delay against `Date()` directly would compare a
    /// deadline in the injected clock's domain to real wall time, which under a test's fixed
    /// 1970 clock is a deadline decades in the past — an instant, spurious expiry.
    var currentTime: Date { now() }

    /// Opens a window, replacing any window already open — two live codes at once would
    /// mean a code the user has forgotten about is still a key.
    ///
    /// Replacing goes through `clearPending()`, not a direct assignment, so a window this
    /// call ends announces that the same way cancelling, claiming or expiring one does. Ending
    /// a live window without firing `onWindowClosed` is exactly the shape of the QR path's
    /// defect — this route just reaches it by opening a new window instead of failing to close
    /// one. `FleetService.arm()` already calls `cancel()` immediately before this, so in
    /// production this fires `onWindowClosed` a second, harmless time when a window was open;
    /// `closePairingListener()` tolerates being called with nothing to close.
    func arm(macName: String, serviceName: String, endpoints: [String]) -> ArmedPairing {
        clearPending()
        let key = FleetDeviceKey.mint()
        // Minted here, beside the device key, and from the same CSPRNG. The two are
        // independent secrets for independent jobs — the key is what the phone keeps, the code
        // is only ever a password for one SPAKE2 exchange inside this window — and neither is
        // derived from the other.
        let code = PairingCode.mint()
        // A placeholder, and only ever briefly: the device names itself in its `hello`, and
        // `FleetService.noteAttached` adopts that the instant it attaches. It survives only
        // for a device that claims nothing — and a provisional row is never listed anyway.
        pending = PairedDevice(
            slot: key.slot, name: "New device", secret: key.secret,
            pairedAt: nil, lastSeenAt: nil, armedUntil: now().addingTimeInterval(Self.window)
        )
        return ArmedPairing(
            payload: PairingPayload(
                key: key, macName: macName, serviceName: serviceName, endpoints: endpoints
            ),
            code: code
        )
    }

    /// Unconditionally, including when no window was open: "cancelled" means there is no
    /// window now, and the listener's lifetime tracks that statement rather than the
    /// transition. It is what lets `FleetService.arm()` open a window without first proving
    /// the previous one left nothing behind.
    func cancel() { clearPending() }

    /// A device completed a handshake on `slot`. Returns whether that closes the window —
    /// i.e. whether this is the device the user just armed for.
    ///
    /// This is the QR path's *only* signal that pairing finished. A phone that scanned the
    /// code never touches the pairing listener at all — it dials the fleet listener with the
    /// key the QR carried — so if the window does not close here it does not close at all.
    func claim(slot: UUID) -> Bool {
        guard let pending, pending.slot == slot else { return false }
        guard let armedUntil = pending.armedUntil, now() <= armedUntil else { return false }
        clearPending()
        return true
    }

    /// Drops a window that has run out. Called on a timer by the UI, and again before every
    /// listener restart, so an expired slot's key stops being accepted rather than merely
    /// stopping being displayed.
    func expire() {
        guard let armedUntil = pending?.armedUntil, now() > armedUntil else { return }
        clearPending()
    }

    /// The single choke point. Every route that ends a window comes through here, so
    /// `onWindowClosed` cannot be missed by a route somebody adds later without touching this
    /// file — which is the whole reason it is a function rather than an assignment repeated
    /// at every call site.
    private func clearPending() {
        pending = nil
        onWindowClosed?()
    }
}
