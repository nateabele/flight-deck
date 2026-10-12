import Foundation

/// `[infra.<name>]` in delegate.toml: a cloud machine Flight Deck can bring up, enroll as a
/// host, and take down again. Pure data; the parser owns the rules for which fields a given
/// source needs, so a value that exists is already a valid one.
public struct InfraConfig: Codable, Sendable, Equatable {
    public enum Source: Codable, Sendable, Equatable {
        /// A template Flight Deck ships (`knownPresets`).
        case preset(String)
        /// A repo-relative directory holding the project's own Terraform module.
        case module(String)
    }

    public var source: Source
    public var region: String?
    public var instanceType: String?
    public var arch: String?
    public var diskGB: Int?
    public var spot: Bool
    /// Hard lifetime: the machine is destroyed this long after it comes up. Required, because
    /// a machine that bills by the hour must never be left without an end.
    public var ttl: Duration
    /// Destroyed after this long with no run on it.
    public var idle: Duration
    /// Bring the machine up on demand when a run is routed to it.
    public var autoUp: Bool
    public var vars: [String: String]
    /// Refuse to bring it up if the estimated hourly price is above this.
    public var maxHourly: Double?

    public static let knownPresets = ["aws-linux", "gcp-linux"]
    public static let defaultIdle = Duration(seconds: 1800)

    public init(source: Source, region: String? = nil, instanceType: String? = nil, arch: String? = nil,
                diskGB: Int? = nil, spot: Bool = false, ttl: Duration, idle: Duration = InfraConfig.defaultIdle,
                autoUp: Bool = false, vars: [String: String] = [:], maxHourly: Double? = nil) {
        self.source = source
        self.region = region
        self.instanceType = instanceType
        self.arch = arch
        self.diskGB = diskGB
        self.spot = spot
        self.ttl = ttl
        self.idle = idle
        self.autoUp = autoUp
        self.vars = vars
        self.maxHourly = maxHourly
    }
}
