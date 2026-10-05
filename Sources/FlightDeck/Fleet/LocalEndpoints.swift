import Foundation
import HostKit
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
///
/// **The ranking itself lives in HostKit's `HostEndpoints`**, the one module the app, the macOS
/// hostd and the Linux hostd all link, so what a phone is told and what a host advertises to a
/// controller in `helloAck` cannot rank differently. This file keeps the macOS-only half —
/// `SCDynamicStore`'s primary interface — and is compiled into the `HostDaemon` target too
/// (project.yml), which is how the macOS hostd answers with the same list the phone gets.
enum LocalEndpoints {
    /// One interface as the ranking sees it; see `HostEndpoints.Interface`.
    typealias Interface = HostEndpoints.Interface

    /// The full ranked list, loopback included and last. The input to `routable`, and not
    /// something to hand a client directly — see the type's doc comment.
    static func current(port: UInt16) -> [String] {
        ranked(HostEndpoints.enumerate(), primary: primaryInterfaceName(), port: port)
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
        HostEndpoints.routable(from: ranked, limit: limit)
    }

    /// What the macOS hostd puts in `helloAck`: the same ranking, minus loopback and
    /// link-local (`HostEndpoints.advertised`). Read per hello, so a Mac host that joins the
    /// tailnet advertises it to the next controller that connects.
    static func advertised(port: UInt16) -> [String] {
        HostEndpoints.advertised(HostEndpoints.enumerate(), primary: primaryInterfaceName(), port: port)
    }

    /// Ranks best-first, stable within a rank. See `HostEndpoints.ranked`.
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
        HostEndpoints.ranked(interfaces, primary: primary, port: port)
    }

    /// `100.64.0.0/10` — the shared address space Tailscale assigns from. See
    /// `HostEndpoints.isCGNAT`.
    static func isCGNAT(_ address: String) -> Bool {
        HostEndpoints.isCGNAT(address)
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
}
