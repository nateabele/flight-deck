import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

/// The host side of cross-network pairing: what the Hosting tab's pairing sheet lists, and the
/// one string its copy button hands the other Mac. Pure inputs throughout — no `getifaddrs`,
/// no Tailscale CLI — so every shape is driven exactly.
final class HostPairingAddressesTests: XCTestCase {
    private typealias Interface = HostEndpoints.Interface

    private func iface(_ name: String, _ address: String, p2p: Bool = false, broadcast: Bool = true,
                       loopback: Bool = false) -> Interface {
        Interface(name: name, address: address, isPointToPoint: p2p, isBroadcast: broadcast, isLoopback: loopback)
    }

    // MARK: - list

    /// Tailscale first (its IPv4, then its MagicDNS name), then the LAN, then `.local` — the
    /// order of "most likely to work from wherever the other Mac is". Loopback and link-local
    /// never appear; the tunnel's own interface address is not listed twice.
    func testOrderIsTailscaleThenLANThenLocalName() {
        let entries = HostPairingAddresses.list(
            tailscale: .init(ipv4: ["100.64.0.7"], dnsName: "studio.tail1234.ts.net."),
            interfaces: [iface("lo0", "127.0.0.1", broadcast: false, loopback: true),
                         iface("en0", "192.0.2.20"),
                         iface("utun4", "100.64.0.7", p2p: true, broadcast: false),
                         iface("en7", "169.254.10.2"),
                         iface("bridge100", "198.51.100.1")],
            primary: "en0", localHostName: "studio", port: 47411)
        XCTAssertEqual(entries.map(\.endpoint), [
            "100.64.0.7:47411",
            "studio.tail1234.ts.net:47411",
            "192.0.2.20:47411",
            "198.51.100.1:47411",
            "studio.local:47411",
        ])
        XCTAssertEqual(entries.map(\.kind), [.tailscale, .tailscaleName, .lan, .lan, .bonjour])
    }

    /// No Tailscale CLI (or Tailscale down): the LAN and the `.local` name still stand, and a
    /// tunnel interface that is plainly a tailnet address still leads, labelled as one.
    func testWithoutTheCLIATailnetInterfaceStillLeads() {
        let entries = HostPairingAddresses.list(
            tailscale: nil,
            interfaces: [iface("en0", "192.0.2.5"), iface("utun7", "100.64.0.9", p2p: true, broadcast: false)],
            primary: "en0", localHostName: "mini", port: 52001)
        XCTAssertEqual(entries.map(\.endpoint), ["100.64.0.9:52001", "192.0.2.5:52001", "mini.local:52001"])
        XCTAssertEqual(entries.first?.kind, .tailscale)
    }

    func testNoNetworkAtAllListsOnlyTheLocalName() {
        XCTAssertEqual(HostPairingAddresses.list(tailscale: nil, interfaces: [], primary: nil,
                                                 localHostName: "mini", port: 47411).map(\.endpoint),
                       ["mini.local:47411"])
        XCTAssertEqual(HostPairingAddresses.list(tailscale: nil, interfaces: [], primary: nil,
                                                 localHostName: nil, port: 47411), [])
    }

    // MARK: - tailscale status --json

    func testTailscaleStatusIsReadFromSelf() {
        let json = #"""
        {"BackendState":"Running","TailscaleIPs":["100.64.0.7","2001:db8::1"],
         "Self":{"TailscaleIPs":["100.64.0.7","2001:db8::1"],"DNSName":"studio.tail1234.ts.net."},
         "Peer":{"x":{"TailscaleIPs":["100.64.0.99"]}}}
        """#
        XCTAssertEqual(HostPairingAddresses.tailscale(statusJSON: Data(json.utf8)),
                       .init(ipv4: ["100.64.0.7"], dnsName: "studio.tail1234.ts.net."))
    }

    /// Logged out or stopped, the CLI still answers with a `Self` — whose addresses no peer can
    /// reach. Listing them would put a dead address first.
    func testTailscaleNotRunningGivesNothing() {
        let json = #"{"BackendState":"Stopped","Self":{"TailscaleIPs":["100.64.0.7"],"DNSName":"studio.ts.net."}}"#
        XCTAssertNil(HostPairingAddresses.tailscale(statusJSON: Data(json.utf8)))
        XCTAssertNil(HostPairingAddresses.tailscale(statusJSON: Data("not json".utf8)))
    }

    // MARK: - The copied string

    func testPairingDetailsIsBestAddressThenCode() {
        XCTAssertEqual(PairingDetails.format(endpoint: "100.64.0.7:47411", code: "K7QM-2XPA-9TRB"),
                       "100.64.0.7:47411 K7QM-2XPA-9TRB")
    }

    // MARK: - Parsing what the controller pastes

    func testParseAddressAlone() {
        XCTAssertEqual(PairingDetails.parse("studio.local"), .init(address: "studio.local", code: nil))
        XCTAssertEqual(PairingDetails.parse(" 192.0.2.20 "), .init(address: "192.0.2.20", code: nil))
    }

    func testParseAddressWithPort() {
        XCTAssertEqual(PairingDetails.parse("100.64.0.7:47411"), .init(address: "100.64.0.7:47411", code: nil))
    }

    func testParseAddressPortAndCode() {
        XCTAssertEqual(PairingDetails.parse("100.64.0.7:47411 K7QM-2XPA-9TRB"),
                       .init(address: "100.64.0.7:47411", code: "K7QM-2XPA-9TRB"))
        // A pasted newline, lower case, and the code first: still one address and one code.
        XCTAssertEqual(PairingDetails.parse("k7qm-2xpa-9trb\nstudio.tail1234.ts.net:52001"),
                       .init(address: "studio.tail1234.ts.net:52001", code: "K7QM-2XPA-9TRB"))
    }

    func testParseBracketedIPv6() {
        XCTAssertEqual(PairingDetails.parse("[2001:db8::1]:47411 K7QM-2XPA-9TRB"),
                       .init(address: "[2001:db8::1]:47411", code: "K7QM-2XPA-9TRB"))
        XCTAssertEqual(PairingDetails.parse("[2001:db8::1]"), .init(address: "[2001:db8::1]", code: nil))
    }

    func testParseGarbage() {
        for text in ["", "   ", "hello there friend", "K7QM-2XPA-9TRB", "a b", "studio.local:notaport",
                     "!!!", "studio.local K7QM-2XPA-9TRB extra", "studio.local other.local"] {
            XCTAssertNil(PairingDetails.parse(text), "\(text.debugDescription) parsed")
        }
    }
}
