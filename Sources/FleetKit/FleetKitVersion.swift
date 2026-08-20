import Foundation

/// The wire contract's version, sent in no frame yet and bumped by nothing yet — it exists
/// so that when the phone and the Mac disagree there is somewhere to say so, rather than a
/// version field being retrofitted into a protocol that already has clients.
public enum FleetKitVersion {
    public static let wire = 1
}
