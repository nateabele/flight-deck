import FleetKit
import Foundation

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
    private(set) var pending: PairedDevice?

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
    func arm(macName: String, serviceName: String, endpoints: [String]) -> PairingPayload {
        let key = FleetDeviceKey.mint()
        // A placeholder, and only ever briefly: the device names itself in its `hello`, and
        // `FleetService.noteAttached` adopts that the instant it attaches. It survives only
        // for a device that claims nothing — and a provisional row is never listed anyway.
        pending = PairedDevice(
            slot: key.slot, name: "New device", secret: key.secret,
            pairedAt: nil, lastSeenAt: nil, armedUntil: now().addingTimeInterval(Self.window)
        )
        return PairingPayload(
            key: key, macName: macName, serviceName: serviceName, endpoints: endpoints
        )
    }

    func cancel() { pending = nil }

    /// A device completed a handshake on `slot`. Returns whether that closes the window —
    /// i.e. whether this is the device the user just armed for.
    func claim(slot: UUID) -> Bool {
        guard let pending, pending.slot == slot else { return false }
        guard let armedUntil = pending.armedUntil, now() <= armedUntil else { return false }
        self.pending = nil
        return true
    }

    /// Drops a window that has run out. Called on a timer by the UI, and again before every
    /// listener restart, so an expired slot's key stops being accepted rather than merely
    /// stopping being displayed.
    func expire() {
        guard let armedUntil = pending?.armedUntil, now() > armedUntil else { return }
        pending = nil
    }
}
