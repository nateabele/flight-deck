import Foundation

/// What a host says about itself in reply to `host.info`. Plain strings and numbers, no
/// Darwin-only types, so a Linux hostd fills in the same struct a Mac does.
public struct HostInfo: Codable, Sendable, Equatable {
    public var hostName: String
    /// "macOS" | "Linux".
    public var platform: String
    public var osVersion: String
    public var arch: String
    public var hostdVersion: String
    /// Installed Xcode versions; empty on Linux rather than absent, so a controller never
    /// has to distinguish "no Xcode" from "field missing".
    public var xcode: [String]
    public var docker: String?
    public var diskFreeBytes: Int64
    /// When the host last had nothing running, serving or syncing; nil while it is busy. Also
    /// nil from a hostd too old to report it, which `Decodable` reads as absent rather than
    /// failing the reply (`decodeIfPresent`, synthesized for an optional), and from a host
    /// whose hostd does not track idleness (the macOS hostd today). A controller must read nil
    /// as "do not reap on idle", never as "idle".
    public var idleSince: Date?

    // Explicit raw values: a Swift rename must not change the wire.
    enum CodingKeys: String, CodingKey {
        case hostName = "hostName"
        case platform = "platform"
        case osVersion = "osVersion"
        case arch = "arch"
        case hostdVersion = "hostdVersion"
        case xcode = "xcode"
        case docker = "docker"
        case diskFreeBytes = "diskFreeBytes"
        case idleSince = "idleSince"
    }

    public init(hostName: String, platform: String, osVersion: String, arch: String,
                hostdVersion: String, xcode: [String], docker: String?, diskFreeBytes: Int64,
                idleSince: Date? = nil) {
        self.hostName = hostName
        self.platform = platform
        self.osVersion = osVersion
        self.arch = arch
        self.hostdVersion = hostdVersion
        self.xcode = xcode
        self.docker = docker
        self.diskFreeBytes = diskFreeBytes
        self.idleSince = idleSince
    }
}
