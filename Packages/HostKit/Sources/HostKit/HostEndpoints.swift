import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The pure half of "which addresses is this machine reachable on": the interface walk and the
/// ranking. Shared by three callers that must agree — the app's `LocalEndpoints` (what the phone
/// is told), the macOS hostd and the Linux hostd (what a controller is told in `helloAck`) — and
/// so it lives here, the one module all three link. Moved out of the app's `LocalEndpoints`
/// unchanged; that file's doc comment still explains the ranking's two signals.
///
/// The "which interface is primary" question stays with each platform: macOS answers it from
/// `SCDynamicStore`, which this Foundation-only package cannot import, and a Linux host passes
/// nil (its tunnel still ranks first, by `IFF_POINTOPOINT`).
public enum HostEndpoints {
    /// One interface as the ranking sees it. A plain struct rather than `ifaddrs`, so the
    /// ranking is a pure function a test can drive with a machine's exact shape.
    public struct Interface: Equatable, Sendable {
        public var name: String
        public var address: String
        public var isPointToPoint: Bool
        public var isBroadcast: Bool
        public var isLoopback: Bool

        public init(name: String, address: String, isPointToPoint: Bool, isBroadcast: Bool,
                    isLoopback: Bool) {
            self.name = name
            self.address = address
            self.isPointToPoint = isPointToPoint
            self.isBroadcast = isBroadcast
            self.isLoopback = isLoopback
        }
    }

    /// The cap on a host's `helloAck` list. Every entry a controller stores is one more
    /// parallel dial in `HostLink`'s race, so a host with a VM bridge per hypervisor must not
    /// hand over all of them; four leaves room for a tunnel, the LAN and two others.
    public static let maxAdvertised = 4

    /// What a hostd advertises in `helloAck`: ranked best-first, then loopback and link-local
    /// dropped, then capped. Loopback names the *controller's* own machine from anywhere a
    /// controller is; a `169.254/16` address is reachable only on one physical link and never
    /// across a tailnet, so storing it costs a race slot for nothing.
    public static func advertised(_ interfaces: [Interface], primary: String?, port: UInt16,
                                  limit: Int = maxAdvertised) -> [String] {
        let usable = interfaces.filter { !$0.isLoopback && !isLinkLocal($0.address) }
        return Array(ranked(usable, primary: primary, port: port).prefix(limit))
    }

    /// What a phone is told: ranked, loopback dropped, capped. Split from the walk so a test
    /// can drive it without a network.
    public static func routable(from ranked: [String], limit: Int) -> [String] {
        Array(ranked.filter { !$0.hasPrefix("127.") }.prefix(limit))
    }

    /// Ranks best-first. Stable within a rank by construction: one `filter` per rank,
    /// concatenated, because `sorted(by:)` promises no stability (see `LocalEndpoints`).
    public static func ranked(_ interfaces: [Interface], primary: String?, port: UInt16) -> [String] {
        (0...lastRank).flatMap { rank in
            interfaces.filter { self.rank(of: $0, primary: primary) == rank }
        }
        .map { "\($0.address):\(port)" }
    }

    /// The worst (highest) value `rank(of:primary:)` can return. Kept beside it so the bucket
    /// range in `ranked` and the rank scale cannot drift apart — a rank above this would
    /// silently vanish from the output rather than merely sort last.
    private static let lastRank = 4

    /// 0 is best.
    private static func rank(of interface: Interface, primary: String?) -> Int {
        // Checked first: a loopback interface is never a useful candidate whatever else it is.
        if interface.isLoopback { return 4 }
        // A tunnel reaches this machine from anywhere the client is signed in. CGNAT tells
        // Tailscale from another VPN only to order two tunnels; either outranks the LAN.
        if interface.isPointToPoint { return isCGNAT(interface.address) ? 0 : 1 }
        if let primary, interface.name == primary { return 2 }
        if interface.isBroadcast { return 3 }
        return 4
    }

    /// `100.64.0.0/10`, the shared address space Tailscale assigns from. The mask matters:
    /// `100.128.0.1` is ordinary public space, and `hasPrefix("100.")` would rank it a tunnel.
    public static func isCGNAT(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, octets[0] == 100 else { return false }
        return (64...127).contains(octets[1])
    }

    /// `169.254.0.0/16`, IPv4 link-local (an interface with no DHCP answer, or a Thunderbolt
    /// bridge).
    public static func isLinkLocal(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 169 && octets[1] == 254
    }

    /// Every up IPv4 interface, loopback included, in kernel order.
    ///
    /// IPv4 only: a link-local IPv6 address needs a zone index to be dialable and would produce
    /// candidates that never connect. Portable across Darwin and glibc, whose `ifaddrs` differ
    /// in two places — `sa_family` is a `UInt8` beside an `sa_len` on Darwin and a `UInt16`
    /// with no length on Linux — so the length handed to `getnameinfo` is the IPv4 sockaddr's.
    public static func enumerate() -> [Interface] {
        var interfaces: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int(entry.pointee.ifa_flags)
            guard flags & Int(IFF_UP) != 0, let raw = entry.pointee.ifa_addr,
                  Int32(raw.pointee.sa_family) == AF_INET
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                raw, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            interfaces.append(Interface(
                name: String(cString: entry.pointee.ifa_name),
                address: String(cString: host),
                isPointToPoint: flags & Int(IFF_POINTOPOINT) != 0,
                isBroadcast: flags & Int(IFF_BROADCAST) != 0,
                isLoopback: flags & Int(IFF_LOOPBACK) != 0
            ))
        }
        return interfaces
    }
}
