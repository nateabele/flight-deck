import Foundation
import Network
import XCTest
@testable import FleetKit

@MainActor
final class PairingDiscoveryTests: XCTestCase {
    private var listener: PairingListener?
    private var browser: PairingBrowser?

    override func tearDown() async throws {
        browser?.stop()
        browser = nil
        listener?.stop()
        listener = nil
    }

    func testThePairingServiceTypeIsNotTheFleetsAndIsWhatTheBrowserLooksFor() {
        XCTAssertEqual(PairingChannel.bonjourType, "_flightdeck-pair._tcp")
        XCTAssertNotEqual(PairingChannel.bonjourType, FleetSocketServer.bonjourType)
    }

    /// An armed Mac is findable, and it says who it is. If this hangs on a first run, macOS is
    /// asking for local-network permission — answer it once and re-run.
    ///
    /// Asserts the expected name is *among* the results rather than that it is the only one:
    /// a development machine may have a real Flight Deck armed on the same LAN, and a test
    /// that failed for that reason would be testing the network rather than the code.
    func testAnArmedMacIsDiscoverableWithItsDisplayName() async throws {
        let serviceName = "flightdeck-test-\(UUID().uuidString.prefix(8))"
        let listener = PairingListener()
        self.listener = listener
        _ = try await listener.start(
            code: .mint(), key: .mint(), macName: "Nate's MacBook",
            serviceName: serviceName, port: nil
        )

        let found = expectation(description: "discovered")
        let browser = PairingBrowser()
        self.browser = browser
        browser.onResults = { macs in
            guard let mine = macs.first(where: { $0.serviceName == serviceName }) else { return }
            XCTAssertEqual(mine.displayName, "Nate's MacBook")
            found.fulfill()
        }
        browser.start()
        await fulfillment(of: [found], timeout: 20)
    }

    /// Invariant 2, discovery half: the advertisement's lifetime is the window's lifetime, so
    /// a Mac that is no longer armed is not merely unreachable — it is not offered.
    func testAMacThatStoppedArmingLeavesTheBrowseResults() async throws {
        let serviceName = "flightdeck-test-\(UUID().uuidString.prefix(8))"
        let listener = PairingListener()
        self.listener = listener
        _ = try await listener.start(
            code: .mint(), key: .mint(), macName: "Briefly Armed",
            serviceName: serviceName, port: nil
        )

        let appeared = expectation(description: "appeared")
        let vanished = expectation(description: "vanished")
        nonisolated(unsafe) var hasAppeared = false
        let browser = PairingBrowser()
        self.browser = browser
        browser.onResults = { macs in
            let present = macs.contains { $0.serviceName == serviceName }
            if present, !hasAppeared {
                hasAppeared = true
                appeared.fulfill()
            } else if !present, hasAppeared {
                vanished.fulfill()
            }
        }
        browser.start()
        await fulfillment(of: [appeared], timeout: 20)
        listener.stop()
        await fulfillment(of: [vanished], timeout: 20)
    }
}
