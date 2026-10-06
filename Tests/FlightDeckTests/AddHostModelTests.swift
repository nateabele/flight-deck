import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// The Add Host sheet's state, outside SwiftUI: what the Mac tab pairs with, when it admits
/// Bonjour found nothing, and what a pasted "address code" string does to its two fields.
@MainActor
final class AddHostModelTests: XCTestCase {
    private final class FakeBrowser: HostPairingBrowsing {
        var onResults: (([PairingBrowser.DiscoveredMac]) -> Void)?
        var started = 0, stopped = 0
        func start() { started += 1 }
        func stop() { stopped += 1 }
    }

    private func mac(_ name: String) -> PairingBrowser.DiscoveredMac {
        .init(serviceName: name, displayName: name, endpoint: .hostPort(host: "192.0.2.1", port: 1))
    }

    // MARK: - The not-found hint

    /// Bonjour does not cross a tailnet, so a Mac tab left searching must eventually say so —
    /// while still searching, in case the host is merely slow to advertise.
    func testHintAppearsWhenNothingIsFoundInTime() async {
        let browser = FakeBrowser()
        let model = AddHostModel(browser: browser, notFoundDelay: 0.01)
        XCTAssertFalse(model.showsNotFoundHint)
        await model.start().value
        XCTAssertEqual(browser.started, 1)
        XCTAssertTrue(model.showsNotFoundHint)
    }

    func testNoHintWhenAMacIsFound() async {
        let browser = FakeBrowser()
        let model = AddHostModel(browser: browser, notFoundDelay: 0.01)
        let timer = model.start()
        browser.onResults?([mac("studio")])
        await timer.value
        XCTAssertFalse(model.showsNotFoundHint)
        // And a Mac that stops advertising later brings the hint back, rather than leaving
        // an empty list that explains nothing.
        browser.onResults?([])
        XCTAssertTrue(model.showsNotFoundHint)
    }

    func testStopCancelsTheHintAndTheBrowse() async {
        let browser = FakeBrowser()
        let model = AddHostModel(browser: browser, notFoundDelay: 0.05)
        let timer = model.start()
        model.stop()
        await timer.value
        XCTAssertEqual(browser.stopped, 1)
        XCTAssertFalse(model.showsNotFoundHint)
    }

    // MARK: - What the Mac tab pairs with

    func testTheOnlyFoundMacIsSelectedAndATypedAddressWins() {
        let browser = FakeBrowser()
        let model = AddHostModel(browser: browser)
        XCTAssertNil(model.macTarget)
        browser.onResults?([mac("studio")])
        XCTAssertEqual(model.selectedHost, "studio")
        XCTAssertEqual(model.macTarget, .host(mac("studio")))
        // The address field is always usable, and what the user typed is what they meant.
        model.address = " 100.64.0.7 "
        XCTAssertEqual(model.macTarget, .address("100.64.0.7"))
        model.address = "  "
        XCTAssertEqual(model.macTarget, .host(mac("studio")))
    }

    func testTwoMacsWaitForAChoiceAndAVanishedChoiceIsDropped() {
        let browser = FakeBrowser()
        let model = AddHostModel(browser: browser)
        browser.onResults?([mac("a"), mac("b")])
        XCTAssertNil(model.selectedHost)
        model.selectedHost = "b"
        XCTAssertEqual(model.macTarget, .host(mac("b")))
        browser.onResults?([mac("a")])
        XCTAssertEqual(model.selectedHost, "a", "the one Mac left is the one the user means")
    }

    /// Address only, no Bonjour host: pairable once the code is whole.
    func testAddressAloneMakesTheMacTabPairable() {
        let model = AddHostModel(browser: FakeBrowser())
        model.code = "K7QM-2XPA-9TRB"
        XCTAssertFalse(model.canPair(kind: .mac, pairing: false))
        model.address = "studio.tail1234.ts.net"
        XCTAssertTrue(model.canPair(kind: .mac, pairing: false))
        XCTAssertFalse(model.canPair(kind: .mac, pairing: true))
        XCTAssertTrue(model.canPair(kind: .linux, pairing: false))
    }

    // MARK: - Pasting the host's details

    func testPastingTheCopiedDetailsFillsBothFields() {
        let model = AddHostModel(browser: FakeBrowser())
        model.address = "100.64.0.7:47411 K7QM-2XPA-9TRB"
        XCTAssertEqual(model.address, "100.64.0.7:47411")
        XCTAssertEqual(model.code, "K7QM-2XPA-9TRB")
    }

    /// Typing an address leaves an already-entered code alone; only a paste that carries a
    /// code replaces it.
    func testTypingAnAddressLeavesTheCode() {
        let model = AddHostModel(browser: FakeBrowser())
        model.code = "AAAA-BBBB-CCCC"
        model.address = "studio.local"
        XCTAssertEqual(model.address, "studio.local")
        XCTAssertEqual(model.code, "AAAA-BBBB-CCCC")
    }
}
