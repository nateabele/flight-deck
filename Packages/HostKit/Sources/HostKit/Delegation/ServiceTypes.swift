import Foundation

// Services and ports (spec §6.2, §7 steps 4–5). Codecs for the enums live in
// `DelegationWire.swift`.

/// One `L:R` forward: local port `L` on the Mac's 127.0.0.1 to remote port `R` on the host.
public struct PortMapping: Codable, Sendable, Equatable {
    public enum Local: Sendable, Equatable {
        case fixed(UInt16)
        /// Any free local port, chosen at preflight.
        case auto
    }

    public let local: Local
    public let remote: UInt16

    public init(local: Local, remote: UInt16) {
        self.local = local
        self.remote = remote
    }

    /// `"5432"` (N:N), `"15432:5432"`, or `"auto:5432"`. Ports are 1–65535 written as plain
    /// digits: a sign, a space or a 0 is a typo, and silently forwarding the wrong port is the
    /// failure §7 exists to stop before any sync.
    public static func parse(_ s: String) throws -> PortMapping {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            let port = try port(parts[0], in: s)
            return PortMapping(local: .fixed(port), remote: port)
        case 2:
            let remote = try port(parts[1], in: s)
            if parts[0] == "auto" { return PortMapping(local: .auto, remote: remote) }
            return PortMapping(local: .fixed(try port(parts[0], in: s)), remote: remote)
        default:
            throw PortMappingError.invalid(s)
        }
    }

    /// The canonical `L:R` / `auto:R` spelling, which `parse` reads back to the same value.
    public var notation: String {
        switch local {
        case .fixed(let port): return "\(port):\(remote)"
        case .auto: return "auto:\(remote)"
        }
    }

    private static func port(_ text: Substring, in whole: String) throws -> UInt16 {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = UInt16(text), value > 0
        else { throw PortMappingError.invalid(whole) }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case local = "local"
        case remote = "remote"
    }

    /// Refuses port 0 on either side, as `parse` does: the wire must not admit a mapping the
    /// command line cannot, or a peer bug would reach the forwarder as "any port".
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let local = try c.decode(Local.self, forKey: .local)
        let remote = try c.decode(UInt16.self, forKey: .remote)
        if remote == 0 || local == .fixed(0) {
            throw DecodingError.dataCorruptedError(forKey: remote == 0 ? .remote : .local, in: c,
                                                   debugDescription: "port 0 is not a port")
        }
        self.init(local: local, remote: remote)
    }
}

public enum PortMappingError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let s): return "invalid port \"\(s)\"; use N, L:R or auto:R with ports 1-65535"
        }
    }
}

/// Who holds a port, for the §7 conflict message ("held by postgres (pid 812)").
public enum PortHolder: Sendable, Equatable {
    case free
    case process(name: String, pid: Int32)
    /// Docker publishes the port; the process holder would only say `com.docker.backend`.
    case container(name: String)
    /// Another Flight Deck session's forward, by its title.
    case flightDeck(session: String)
    /// Bound, but nothing could say by whom.
    case unknown
}

/// One port's answer in a `port.check` reply. An array of these rather than a dictionary: a
/// Swift `[UInt16: …]` encodes as a flat key/value array, not an object, and is unreadable to
/// anything but another Swift decoder.
public struct PortStatus: Codable, Sendable, Equatable {
    public let port: UInt16
    public let holder: PortHolder

    public init(port: UInt16, holder: PortHolder) {
        self.port = port
        self.holder = holder
    }

    enum CodingKeys: String, CodingKey {
        case port = "port"
        case holder = "holder"
    }
}

/// Names the holder of a port on this machine: the Mac's local preflight (step 4) and the
/// host's `port.check` (step 5) both answer through it. Async because naming a holder shells
/// out (`lsof`, `docker ps`), which must not hold a cooperative thread.
public protocol PortChecking: Sendable {
    func holder(of port: UInt16) async -> PortHolder
}
