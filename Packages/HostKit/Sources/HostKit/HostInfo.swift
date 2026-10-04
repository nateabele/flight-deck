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
    }

    public init(hostName: String, platform: String, osVersion: String, arch: String,
                hostdVersion: String, xcode: [String], docker: String?, diskFreeBytes: Int64) {
        self.hostName = hostName
        self.platform = platform
        self.osVersion = osVersion
        self.arch = arch
        self.hostdVersion = hostdVersion
        self.xcode = xcode
        self.docker = docker
        self.diskFreeBytes = diskFreeBytes
    }
}
