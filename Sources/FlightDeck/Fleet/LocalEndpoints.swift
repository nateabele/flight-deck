import Foundation
import SystemConfiguration

/// Every address this Mac can currently be reached on, ranked best-first, as `host:port`
/// candidates for the pairing code and for the `mac.endpoints` reply.
///
/// These are candidates, not an address. The key identifies the Mac (§3); by the time the
/// phone has left the room every one of these may be wrong, which is why the phone races
/// them rather than trusting one — and why `FleetRequest.macEndpoints` exists to ask again.
///
/// **Ranked rather than enumerated**, because only the first two reach a QR and kernel order
/// put a VM bridge ahead of the tailnet address. The two signals used are supplied by macOS
/// directly, so no interface name is ever matched: `SCDynamicStore`'s `PrimaryInterface`
/// names the real LAN interface (the one carrying the default route), and `IFF_POINTOPOINT`
/// names a tunnel. On the Mac this was written for, that separates `en0` from three
/// `bridge*` interfaces belonging to Internet Sharing and a VM, and finds `utun7` without
/// knowing what Tailscale is called.
///
/// Loopback is enumerated and ranked last. It is NOT here for the loopback tests — every one
/// of those builds its own endpoint array (`FleetConnectorTests`, `PairedMacStoreTests`) or
/// calls `FleetService.loopbackEndpoint()`. It is here so a Mac with no network at all still
/// produces a list rather than an empty one.
///
/// Ranking it last is not, by itself, enough to keep it off the wire, and an earlier revision
/// of this comment claimed otherwise: `127.0.0.1:<port>` packs into a pairing code as happily
/// as any other IPv4:port, so on a Wi-Fi-only Mac (`lo0` + `en0` and nothing else) it landed
/// in the QR's second slot and the phone raced a dial to itself. **`routable` is what drops
/// it, so every path that reaches a client goes through `routable` — both the `mac.endpoints`
/// reply and `FleetService.arm()`.** `current` is the unfiltered list, and nothing but
/// `routable` should call it.
enum LocalEndpoints {
    /// One interface as the ranking sees it.
    ///
    /// A plain struct rather than `ifaddrs`, so `ranked` is a pure function that can be
    /// tested against a machine's exact interface shape without that machine.
    struct Interface: Equatable {
        var name: String
        var address: String
        var isPointToPoint: Bool
        var isBroadcast: Bool
        var isLoopback: Bool
    }

    /// The full ranked list, loopback included and last. The input to `routable`, and not
    /// something to hand a client directly — see the type's doc comment.
    static func current(port: UInt16) -> [String] {
        ranked(enumerate(), primary: primaryInterfaceName(), port: port)
    }

    /// What a connected client is told: ranked, loopback dropped, capped.
    ///
    /// Capped because every candidate a phone stores becomes a real parallel connection
    /// attempt in `FleetConnector.race()` — an uncapped list would spend the race on VM
    /// bridges no phone can reach.
    static func routable(port: UInt16, limit: Int) -> [String] {
        routable(from: current(port: port), limit: limit)
    }

    /// Split out so a test can drive it without a network.
    static func routable(from ranked: [String], limit: Int) -> [String] {
        Array(ranked.filter { !$0.hasPrefix("127.") }.prefix(limit))
    }

    /// Ranks best-first. Stable within a rank, by construction rather than by sort.
    ///
    /// Bucketed rather than sorted, and that is the point: `Array.sorted(by:)` makes no
    /// stability guarantee, so ordering equal-rank candidates through it would rest on an
    /// incidental behaviour of the current stdlib. (Measured on Swift 6.3.3/arm64: it does
    /// preserve tied order at every size and shape tried, 20 through 100,000 — which is
    /// precisely the problem. A guarantee nothing promises is one no test can defend, and a
    /// later toolchain is free to withdraw it silently.) `filter` preserves relative order
    /// by definition, so concatenating one bucket per rank is stable by construction, and
    /// there is no tiebreak key left for a refactor to "simplify" away.
    static func ranked(_ interfaces: [Interface], primary: String?, port: UInt16) -> [String] {
        (0...Self.lastRank).flatMap { rank in
            interfaces.filter { self.rank(of: $0, primary: primary) == rank }
        }
        .map { "\($0.address):\(port)" }
    }

    /// The worst (highest) value `rank(of:primary:)` can return. Kept alongside it so the
    /// bucket range in `ranked` and the rank scale itself cannot drift apart — a rank above
    /// this would silently vanish from the output rather than merely sort last.
    private static let lastRank = 4

    /// 0 is best. See the type's doc comment for why these two signals and not a name.
    private static func rank(of interface: Interface, primary: String?) -> Int {
        // Checked first: a loopback interface is never a useful candidate whatever else it is.
        if interface.isLoopback { return 4 }
        // A tunnel reaches this Mac from anywhere the client is signed in, which is the whole
        // point of the change. CGNAT distinguishes Tailscale from another VPN only to order
        // two tunnels; either still outranks the LAN.
        if interface.isPointToPoint { return isCGNAT(interface.address) ? 0 : 1 }
        // macOS's own answer for "the interface that reaches the internet".
        if let primary, interface.name == primary { return 2 }
        if interface.isBroadcast { return 3 }
        // Neither a tunnel, nor primary, nor a broadcast segment. Last resort, with loopback.
        return 4
    }

    /// `100.64.0.0/10` — the shared address space Tailscale assigns from.
    ///
    /// The mask matters: `100.128.0.1` is ordinary public space and a naive `hasPrefix("100.")`
    /// would rank a public address as a tunnel.
    static func isCGNAT(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, octets[0] == 100 else { return false }
        return (64...127).contains(octets[1])
    }

    /// The interface macOS considers primary, or nil when there is no network.
    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(
            nil, "dev.flightdeck.LocalEndpoints" as CFString, nil, nil
        ),
        let global = SCDynamicStoreCopyValue(
            store, "State:/Network/Global/IPv4" as CFString
        ) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    /// IPv4 only. A link-local IPv6 address needs a zone index to be dialable and would
    /// produce candidates that can never connect — noise in a race that is already parallel.
    private static func enumerate() -> [Interface] {
        var interfaces: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let raw = entry.pointee.ifa_addr,
                  raw.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                raw, socklen_t(raw.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            interfaces.append(Interface(
                name: String(cString: entry.pointee.ifa_name),
                address: String(cString: host),
                isPointToPoint: flags & IFF_POINTOPOINT != 0,
                isBroadcast: flags & IFF_BROADCAST != 0,
                isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return interfaces
    }
}
