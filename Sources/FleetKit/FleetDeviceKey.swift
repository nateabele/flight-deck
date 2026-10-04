import Foundation
#if canImport(Security)
import Security
#else
import Glibc
#endif

/// One paired device: the slot the Mac filed it under, and the secret they share.
///
/// The slot id doubles as the TLS PSK *identity*, which is what lets one listener hold
/// several devices' keys and still know which one connected — and what makes revoking a
/// device exactly "delete this slot's secret" with no other bookkeeping.
///
/// Its own file, out of `FleetTLS.swift`, because the Linux hostd compiles it directly
/// (Packages/HostDaemonLinux/Sources/PairingCore symlinks it) and FleetTLS is Network-only.
public struct FleetDeviceKey: Equatable, Sendable {
    public let slot: UUID
    /// 32 bytes from the system CSPRNG. Never derived from anything the user types: this is
    /// displayed once, in a QR, on a screen the user is looking at (§3), so there is no
    /// password to stretch and nothing to be memorable.
    public let secret: Data

    public init(slot: UUID, secret: Data) {
        self.slot = slot
        self.secret = secret
    }

    public static func mint() -> FleetDeviceKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A failure here means the system CSPRNG is unavailable, which is not a condition
        // to paper over with a weaker key — there is no safe fallback, so trap. The Linux
        // branch traps on the same condition for the same reason.
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        #else
        // getentropy is the Linux CSPRNG with no fd and no partial reads below 256 bytes.
        precondition(getentropy(&bytes, bytes.count) == 0, "getentropy failed: \(errno)")
        #endif
        return FleetDeviceKey(slot: UUID(), secret: Data(bytes))
    }

    /// The PSK identity blob. The slot's UUID string rather than its raw bytes, so a packet
    /// capture and the paired-devices list in Preferences name the same thing.
    var identity: Data { Data(slot.uuidString.utf8) }
}
