import Foundation

/// One paired host as `hosts.json` stores it. Never holds the secret: that lives in
/// `HostSecretStoring`, keyed by `slot`, so a copied or backed-up `hosts.json` grants nothing.
struct HostRecord: Codable, Equatable, Identifiable {
    /// The TLS-PSK identity this controller authenticates as on that host.
    let slot: UUID
    /// What the user and `flightdeck host …` call it. Unique within the registry
    /// (case-insensitively), because the CLI resolves hosts by this name.
    var name: String
    /// The host's `_fd-host._tcp` Bonjour instance name, which `HostLink` browses for.
    var serviceName: String
    /// `host:port` texts, most recently winning first, at most `PairingPayload.maxEndpoints`.
    var endpoints: [String]
    /// "macOS" | "Linux", from the host's last `host.info`; nil until one has answered.
    var platform: String?
    let pairedAt: Date
    var lastSeenAt: Date?

    var id: UUID { slot }
}

/// Why a host name did not resolve. Carries every paired name so the caller can say which
/// ones exist instead of silently picking one.
enum HostLookupError: Error, Equatable {
    case unknown(available: [String])
}
