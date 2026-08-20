import FleetKit
import Foundation

/// One slot in the paired-devices list.
///
/// A *provisional* device is a window the user has opened and nobody has walked through
/// yet: its key is already live on the listener — it has to be, or the phone could not
/// complete a handshake — but it expires on its own and is discarded if unclaimed. That is
/// what keeps "armed" a moment rather than a state the machine can be left in.
struct PairedDevice: Codable, Equatable, Identifiable {
    let slot: UUID
    /// What the user calls this phone. Named on the Mac, because that is where the list is
    /// managed and where revoking happens.
    var name: String
    var secret: Data
    /// When the first successful handshake happened. `nil` while provisional.
    var pairedAt: Date?
    var lastSeenAt: Date?
    /// Set only while provisional; the instant after which this slot must be discarded.
    var armedUntil: Date?

    var id: UUID { slot }
    var isProvisional: Bool { pairedAt == nil }

    func key() -> FleetDeviceKey { FleetDeviceKey(slot: slot, secret: secret) }
}
