import Network
import XCTest
@testable import FleetKit

/// That a fleet socket probes a peer that has stopped answering.
///
/// **This is a configuration assertion, and it is worth having precisely because the failure it
/// guards is invisible.** Without keepalive an `NWConnection` whose peer vanished without a FIN
/// stays `.ready` forever: no state change, so `FleetConnector` never retries, so a phone in
/// the foreground is wedged until it is force-quit. Nothing about that presents as an error —
/// it presents as a fleet list that has simply stopped changing.
///
/// What a unit test can reach is that the option is set. Whether the probes actually recover a
/// real dead connection is docs/MOBILE.md's, since it needs two devices and a network.
final class FleetTLSKeepaliveTests: XCTestCase {

    private func tcp(_ parameters: NWParameters) throws -> NWProtocolTCP.Options {
        try XCTUnwrap(
            parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options,
            "the fleet stack must be TCP for any of this to mean anything"
        )
    }

    func testAClientProbesAPeerThatStoppedAnswering() throws {
        let options = try tcp(FleetTLS.clientParameters(key: .mint()))
        XCTAssertTrue(options.enableKeepalive, "a silent peer is undetectable without this")
        XCTAssertEqual(options.keepaliveIdle, 10)
        XCTAssertEqual(options.keepaliveInterval, 5)
        XCTAssertEqual(options.keepaliveCount, 3)
    }

    /// Both ends, so a Mac holding a connection to a phone that vanished releases its slot
    /// rather than counting a ghost as attached.
    func testTheListenerProbesToo() throws {
        let options = try tcp(FleetTLS.listenerParameters(keys: [.mint()]))
        XCTAssertTrue(options.enableKeepalive)
    }
}
