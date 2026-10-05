import XCTest
@testable import HostKit

final class HostEndpointsTests: XCTestCase {
    private func iface(_ name: String, _ address: String, p2p: Bool = false, broadcast: Bool = true,
                       loopback: Bool = false) -> HostEndpoints.Interface {
        .init(name: name, address: address, isPointToPoint: p2p, isBroadcast: broadcast, isLoopback: loopback)
    }

    /// A Linux box as `getifaddrs` reports it with Tailscale up and Docker installed.
    private func linuxBox() -> [HostEndpoints.Interface] {
        [
            iface("lo", "127.0.0.1", broadcast: false, loopback: true),
            iface("eth0", "192.168.1.40"),
            iface("docker0", "172.17.0.1"),
            iface("eth1", "169.254.12.7"),
            iface("tailscale0", "100.101.102.103", p2p: true, broadcast: false),
        ]
    }

    /// What a host advertises: the tailnet address first (it is the one that still works once
    /// the controller leaves the LAN), loopback and link-local never (both name the wrong
    /// machine, or no reachable one, from anywhere a controller is).
    func testAdvertisedDropsLoopbackAndLinkLocalAndLeadsWithTheTailnet() {
        XCTAssertEqual(HostEndpoints.advertised(linuxBox(), primary: nil, port: 47410),
                       ["100.101.102.103:47410", "192.168.1.40:47410", "172.17.0.1:47410"])
    }

    func testAdvertisedIsCapped() {
        let many = (1...9).map { iface("eth\($0)", "10.0.0.\($0)") }
        XCTAssertEqual(HostEndpoints.advertised(many, primary: nil, port: 1).count, HostEndpoints.maxAdvertised)
    }

    /// CGNAT on an interface that is not point-to-point (Tailscale in userspace mode, some
    /// container setups) is still advertised, not filtered as odd.
    func testCGNATOffATunnelIsStillAdvertised() {
        let box = [iface("eth0", "192.168.1.40"), iface("ts", "100.64.0.9")]
        XCTAssertEqual(Set(HostEndpoints.advertised(box, primary: nil, port: 47410)),
                       ["192.168.1.40:47410", "100.64.0.9:47410"])
    }

    func testLinkLocal() {
        XCTAssertTrue(HostEndpoints.isLinkLocal("169.254.0.1"))
        XCTAssertTrue(HostEndpoints.isLinkLocal("169.254.255.254"))
        XCTAssertFalse(HostEndpoints.isLinkLocal("169.253.0.1"))
        XCTAssertFalse(HostEndpoints.isLinkLocal("192.168.1.1"))
    }

    /// The real `getifaddrs` walk, on whichever platform runs this (test-hostkit.sh runs it on
    /// macOS and in a Linux container): every machine has an up IPv4 loopback, so an empty or
    /// loopback-less result is a walk that misreads the platform's `ifaddrs` layout.
    func testEnumerateFindsTheLoopbackInterface() {
        let found = HostEndpoints.enumerate()
        XCTAssertTrue(found.contains { $0.isLoopback && $0.address == "127.0.0.1" }, "\(found)")
        XCTAssertFalse(found.contains { $0.address.contains(":") }, "IPv4 only: \(found)")
    }
}
