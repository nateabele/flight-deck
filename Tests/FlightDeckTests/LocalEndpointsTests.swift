import XCTest
@testable import FlightDeck

final class LocalEndpointsTests: XCTestCase {
    /// The exact interface shape of the Mac that could not pair, 2026-08-25.
    private func affectedMac() -> [LocalEndpoints.Interface] {
        [
            .init(name: "lo0", address: "127.0.0.1", isPointToPoint: false, isBroadcast: false, isLoopback: true),
            .init(name: "en0", address: "192.168.1.109", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "bridge100", address: "192.168.139.3", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "bridge101", address: "192.168.117.0", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "bridge102", address: "192.168.97.0", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "utun7", address: "100.108.99.35", isPointToPoint: true, isBroadcast: false, isLoopback: false),
        ]
    }

    /// The defect, as an assertion: the tailnet address must come first and the Wi-Fi address
    /// second, so the two that fit in a QR are the two that can actually carry a connection.
    func testTheTailnetAddressOutranksWiFiAndBothBeatTheBridges() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "en0", port: 58625)
        XCTAssertEqual(
            Array(ranked.prefix(2)),
            ["100.108.99.35:58625", "192.168.1.109:58625"]
        )
    }

    func testLoopbackRanksLast() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "en0", port: 58625)
        XCTAssertEqual(ranked.last, "127.0.0.1:58625")
    }

    /// With an exit node the primary interface IS the tunnel, so the rule that fills the LAN
    /// slot names an interface the VPN rule already took. Both slots must still be populated.
    func testAnExitNodeStillLeavesALANCandidate() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "utun7", port: 58625)
        XCTAssertEqual(ranked.first, "100.108.99.35:58625")
        XCTAssertEqual(ranked.dropFirst().first, "192.168.1.109:58625")
    }

    func testWithNoVPNThePrimaryInterfaceComesFirst() {
        let withoutVPN = affectedMac().filter { $0.name != "utun7" }
        let ranked = LocalEndpoints.ranked(withoutVPN, primary: "en0", port: 58625)
        XCTAssertEqual(ranked.first, "192.168.1.109:58625")
    }

    /// No primary is a real state — no network at all — and must not trap.
    func testNoPrimaryInterfaceStillProducesAList() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: nil, port: 58625)
        XCTAssertEqual(ranked.first, "100.108.99.35:58625")
        XCTAssertEqual(ranked.count, 6)
    }

    /// Equal ranks must keep enumeration order. `Array.sorted` is NOT stable, so this fails
    /// against the obvious one-key implementation.
    func testInterfacesOfEqualRankKeepTheirEnumerationOrder() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "en0", port: 58625)
        XCTAssertEqual(
            ranked,
            ["100.108.99.35:58625", "192.168.1.109:58625", "192.168.139.3:58625",
             "192.168.117.0:58625", "192.168.97.0:58625", "127.0.0.1:58625"]
        )
    }

    /// 100.64/10, not "anything starting 100." — 100.128.0.1 is ordinary public space.
    func testOnlyTheCGNATRangeCountsAsATailnetAddress() {
        XCTAssertTrue(LocalEndpoints.isCGNAT("100.64.0.1"))
        XCTAssertTrue(LocalEndpoints.isCGNAT("100.127.255.254"))
        XCTAssertFalse(LocalEndpoints.isCGNAT("100.63.255.255"))
        XCTAssertFalse(LocalEndpoints.isCGNAT("100.128.0.1"))
        XCTAssertFalse(LocalEndpoints.isCGNAT("192.168.1.1"))
    }

    /// What the `mac.endpoints` reply sends: ranked, capped, and loopback removed — a phone
    /// dialling 127.0.0.1 is spending one of its parallel race slots on itself.
    func testRoutableDropsLoopbackAndCaps() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "en0", port: 58625)
        let routable = LocalEndpoints.routable(from: ranked, limit: 4)
        XCTAssertEqual(routable.count, 4)
        XCTAssertFalse(routable.contains("127.0.0.1:58625"))
        XCTAssertEqual(routable.first, "100.108.99.35:58625")
    }
}
