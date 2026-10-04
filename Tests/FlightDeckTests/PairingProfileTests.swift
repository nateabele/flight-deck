import Foundation
import Network
import Security
import XCTest
@testable import FleetKit

@MainActor
final class PairingProfileTests: XCTestCase {
    private var listener: PairingListener?

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    func testPhoneProfileIsTheShippedConstants() {
        XCTAssertEqual(PairingProfile.phone.bonjourType, "_flightdeck-pair._tcp")
        XCTAssertEqual(PairingProfile.phone.initiatorName, Data("flightdeck-phone".utf8))
        XCTAssertEqual(PairingProfile.phone.responderName, Data("flightdeck-mac".utf8))
        // `PairingChannel`'s copies are what the iOS app reads; they must be the profile's.
        XCTAssertEqual(PairingChannel.bonjourType, PairingProfile.phone.bonjourType)
        XCTAssertEqual(PairingChannel.initiatorName, PairingProfile.phone.initiatorName)
        XCTAssertEqual(PairingChannel.responderName, PairingProfile.phone.responderName)
    }

    /// Domain separation: a code typed into a host pairing must never complete against a phone
    /// pairing window, and vice versa — SPAKE2 names are bound into the key, so differing names
    /// make the confirmations mismatch.
    func testHostProfileIsDomainSeparated() {
        XCTAssertEqual(PairingProfile.host.bonjourType, "_fd-host-pair._tcp")
        XCTAssertLessThanOrEqual(PairingProfile.host.bonjourType.split(separator: ".")[0].count - 1, 15)
        XCTAssertNotEqual(PairingProfile.host.initiatorName, PairingProfile.phone.initiatorName)
        XCTAssertNotEqual(PairingProfile.host.responderName, PairingProfile.phone.responderName)
    }

    /// The profile's raw suite numbers are the transport's, not a second copy that could drift:
    /// a host profile carrying 0x00A8 would pair Mac-to-Mac and fail against every Linux host.
    func testProfilesCarryTheirTransportsSuites() {
        XCTAssertEqual(PairingProfile.phone.tlsSuites, [0x00A8])
        XCTAssertEqual(PairingProfile.host.tlsSuites, [0xCCAC])
        XCTAssertEqual(PairingProfile.phone.tlsSuites, FleetTLS.phoneSuites.map(\.rawValue))
        XCTAssertEqual(PairingProfile.host.tlsSuites, FleetTLS.hostSuites.map(\.rawValue))
    }

    func testHostInitiatorFailsAgainstPhoneListener() async throws {
        // Arm a phone-profile PairingListener on loopback and dial it with a host-profile
        // PairingInitiator using the right code: expect `.wrongCode`, never `onPaired`.
        let listener = PairingListener(profile: .phone)
        self.listener = listener
        let code = PairingCode.mint()
        let port = try await listener.start(code: code, key: .mint(), macName: "m",
                                            serviceName: "t-\(UUID())", port: nil)
        let initiator = PairingInitiator(profile: .host)
        let failed = expectation(description: "fails")
        initiator.onPaired = { _, _ in XCTFail("cross-profile pairing must not succeed") }
        initiator.onFailure = { failure in XCTAssertEqual(failure, .wrongCode); failed.fulfill() }
        initiator.start(code: code, endpoint: .hostPort(host: "127.0.0.1", port: port))
        await fulfillment(of: [failed], timeout: 15)
    }

    /// The control for the test above: the same code over the same loopback pairs when both
    /// ends are the host profile, so the failure there is the names, not the transport.
    func testHostProfilePairsWithItself() async throws {
        let listener = PairingListener(profile: .host)
        self.listener = listener
        let code = PairingCode.mint()
        let key = FleetDeviceKey.mint()
        let port = try await listener.start(code: code, key: key, macName: "host-a",
                                            serviceName: "t-\(UUID())", port: nil)
        let initiator = PairingInitiator(profile: .host)
        let paired = expectation(description: "paired")
        initiator.onPaired = { got, name in
            XCTAssertEqual(got, key)
            XCTAssertEqual(name, "host-a")
            paired.fulfill()
        }
        initiator.onFailure = { XCTFail("host-profile pairing failed: \($0)") }
        initiator.start(code: code, endpoint: .hostPort(host: "127.0.0.1", port: port))
        await fulfillment(of: [paired], timeout: 15)
    }

    /// The phone's bootstrap is byte-for-byte what it was before profiles existed, so a real
    /// `PairingListener(profile: .phone)` dialled with the public phone client still settles on
    /// 0x00A8. A drift here would mean every shipped phone negotiating something new.
    func testPhonePairingBootstrapStillNegotiatesPSKAES128GCM() async throws {
        let port = try await arm(.phone)
        let negotiated = try await handshake(port, FleetTLS.pairingClientParameters())
        XCTAssertEqual(negotiated.suite, 0x00A8)
        XCTAssertEqual(negotiated.version, tls_protocol_version_t.TLSv12.rawValue)
    }

    /// A host pairing must negotiate 0xCCAC end to end, because a Linux host's BoringSSL has no
    /// 0x00A8 to fall back to. This proves the host-profile *listener* takes it; the Linux leg
    /// (`LinuxHostdInteropTests.testDarwinInitiatorPairsWithLinuxResponder`, against a server
    /// pinned to 0xCCAC) proves the host-profile initiator offers it.
    func testHostPairingNegotiatesECDHEPSKChaCha20() async throws {
        let port = try await arm(.host)
        let negotiated = try await handshake(port, FleetTLS.pairingClientParameters(profile: .host))
        XCTAssertEqual(negotiated.suite, 0xCCAC)
        XCTAssertEqual(negotiated.version, tls_protocol_version_t.TLSv12.rawValue)
    }

    private func arm(_ profile: PairingProfile) async throws -> NWEndpoint.Port {
        let listener = PairingListener(profile: profile)
        self.listener = listener
        return try await listener.start(code: .mint(), key: .mint(), macName: "m",
                                        serviceName: "t-\(UUID())", port: nil)
    }

    /// Dials the pairing listener the way the initiator does (TLS under WebSocket) and reports
    /// what the handshake settled on. Nothing is sent: the suite is decided by `.ready`.
    private func handshake(
        _ port: NWEndpoint.Port, _ tls: NWParameters
    ) async throws -> (suite: UInt16, version: UInt16) {
        let connection = NWConnection(
            to: FleetSocket.webSocketEndpoint(for: .hostPort(host: "127.0.0.1", port: port)),
            using: FleetSocket.webSocketParameters(tls, maximumMessageSize: PairingListener.maxFrameBytes)
        )
        defer { connection.cancel() }
        let ready = expectation(description: "ready")
        connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        connection.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        let tlsMeta = try XCTUnwrap(
            connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        )
        let meta = tlsMeta.securityProtocolMetadata
        return (sec_protocol_metadata_get_negotiated_tls_ciphersuite(meta).rawValue,
                sec_protocol_metadata_get_negotiated_tls_protocol_version(meta).rawValue)
    }
}
