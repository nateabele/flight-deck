import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// Invariants 2 and 3 of the spec's §6, plus the acceptance test the whole plan exists for.
@MainActor
final class PairingWindowTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private var service: FleetService?
    private var runner: PairingRunner?
    private var client: FleetClient?
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func tearDown() async throws {
        runner?.cancel()
        client?.disconnect()
        service?.stop()
        runner = nil
        client = nil
        service = nil
    }

    private func standUp() async throws -> (PreferencesStore, FleetService) {
        let preferences = PreferencesStore(persistence: MemoryPersistence())
        let service = FleetService(
            store: SessionStore(provider: nil, persistence: nil),
            preferences: preferences,
            armer: PairingArmer(now: { self.now })
        )
        // Silenced for `FleetTestHarness`'s reason: the default prompt-lifecycle sink
        // appends to the developer's own `~/Library/Logs/flight-deck-prompt.log`.
        service.promptLifecycleForTesting = { _ in }
        self.service = service
        _ = try await service.start(port: nil)
        return (preferences, service)
    }

    /// Whether anything is listening on `port` and willing to speak the pairing protocol.
    /// Concluded from a *reply*, never from a connection state: a refused PSK handshake and a
    /// closed port both present as silence, and only an answered frame distinguishes a live
    /// pairing listener from either.
    private func pairingListenerAnswers(on port: NWEndpoint.Port) async -> Bool {
        nonisolated(unsafe) var replied = false
        let probe = PairingProbe(port: port, opensWithPake: true)
        probe.onAnyReply = { MainActor.assumeIsolated { replied = true } }
        probe.start()
        // Polled rather than awaited on an `XCTestExpectation`: this helper answers a
        // question, and half its call sites expect the answer to be `false`. An expectation
        // that timed out would record a test failure on the way to returning it.
        //
        // A wrong code is enough to draw *an* answer — the responder cannot know a code is
        // wrong until the confirmation, so it replies with its own `pake` regardless. This
        // probe therefore never spends an attempt against the window's three.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if replied { break }
        }
        probe.stop()
        return replied
    }

    private func armedPort(_ service: FleetService) throws -> NWEndpoint.Port {
        try XCTUnwrap(service.pairingPort, "arming did not open a pairing listener")
    }

    /// Invariant 2, the positive half: a window that is open is reachable.
    func testArmingOpensThePairingListener() async throws {
        let (_, service) = try await standUp()
        _ = try await service.arm()
        let port = try armedPort(service)
        let answers = await pairingListenerAnswers(on: port)
        XCTAssertTrue(answers, "an armed Mac did not answer on its pairing port")
    }

    /// Invariant 2, every closing route. Each is asserted against the *same* port the
    /// window was opened on, because "the listener is gone" and "the port moved" are different
    /// facts and only the first one is the invariant.
    ///
    /// The list is here for readability, not as the specification: what closes the listener is
    /// the rule on `FleetService.closePairingListener()` — the listener's lifetime is
    /// `armer.pending`'s lifetime — and route 5 is here because the earlier enumeration of
    /// "success, expiry, cancel, termination" read *success* as the typed path's `onPaired`
    /// and silently omitted the QR, which is the other success.
    func testEveryRouteThatClosesTheWindowClosesThePairingListener() async throws {
        // Route 1: explicit cancel.
        let (_, cancelService) = try await standUp()
        _ = try await cancelService.arm()
        let cancelPort = try armedPort(cancelService)
        try await cancelService.cancelArming()
        var answers = await pairingListenerAnswers(on: cancelPort)
        XCTAssertFalse(answers, "cancelling the window left the pairing listener up")
        cancelService.stop()

        // Route 2: expiry.
        let (_, expiryService) = try await standUp()
        _ = try await expiryService.arm()
        let expiryPort = try armedPort(expiryService)
        now += PairingArmer.window + 1
        try await expiryService.expireArming()
        answers = await pairingListenerAnswers(on: expiryPort)
        XCTAssertFalse(answers, "an expired window left the pairing listener up")
        expiryService.stop()

        // Route 3: app termination.
        let (_, stopService) = try await standUp()
        _ = try await stopService.arm()
        let stopPort = try armedPort(stopService)
        stopService.stop()
        answers = await pairingListenerAnswers(on: stopPort)
        XCTAssertFalse(answers, "stopping the service left the pairing listener up")

        // Route 4: success on the typed path. Covered by the acceptance test below, which
        // asserts the same property after a real pairing rather than re-deriving one here.

        // Route 5: success on the QR path. Nothing on the pairing socket witnesses this one —
        // the phone dials the *fleet* listener with the key the QR carried, so no pairing
        // connection, no `onPaired`, and the code the window is still handing out is by now
        // the phone's permanent key. `armer.claim` is the only witness there is.
        //
        // `expireArming()` afterwards is exactly what the sheet does on its way out, and it is
        // deliberately *not* what closes the listener: the claim already cleared `pending`, so
        // that call returns at its first guard. If this passes only because of that line, the
        // route is not covered.
        let (qrPreferences, qrService) = try await standUp()
        let qrArmed = try await qrService.arm()
        let qrPort = try armedPort(qrService)
        let snapshot = expectation(description: "snapshot")
        let qrClient = FleetClient(key: qrArmed.payload.key, deviceName: "Scanning Phone")
        self.client = qrClient
        qrClient.onFrame = { if case .snapshot = $0 { snapshot.fulfill() } }
        qrClient.connect(to: try qrService.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [snapshot], timeout: 15)
        XCTAssertEqual(
            qrPreferences.pairedDevices.first?.isProvisional, false,
            "the QR path did not finish pairing, so what follows would prove nothing"
        )
        try await qrService.expireArming()
        answers = await pairingListenerAnswers(on: qrPort)
        XCTAssertFalse(answers, "pairing by QR left the pairing listener up")
        qrClient.disconnect()
        qrService.stop()
    }

    /// Invariant 3. A `hello` is not in the pairing vocabulary, so it cannot be parsed, so the
    /// connection ends — and nothing reaches the session layer. Asserted three ways, because
    /// "no reply" alone would also be true of a listener that quietly ignored it.
    func testAHelloOnThePairingSocketReachesNothing() async throws {
        let (_, service) = try await standUp()
        _ = try await service.arm()
        let port = try armedPort(service)

        let ended = expectation(description: "connection ended")
        // Silent until the raw `hello` below: a probe that opened with a `pake` would draw
        // a legitimate `pake` back and fail this test for speaking the protocol correctly.
        let probe = PairingProbe(port: port, opensWithPake: false)
        probe.onAnyReply = { XCTFail("the pairing listener answered a fleet frame") }
        probe.onEnd = { ended.fulfill() }
        probe.start()
        try await Task.sleep(for: .milliseconds(300))
        probe.sendRawFleetHello()
        await fulfillment(of: [ended], timeout: 10)

        XCTAssertTrue(
            service.attachedSlots.isEmpty,
            "a bootstrap connection was attributed as an attached device"
        )
    }

    /// The acceptance test this plan exists for, and route 4 of invariant 2 in the same run:
    /// a real armed Mac, a real Bonjour-shaped candidate, a real SPAKE2 exchange over a real
    /// socket, a real sealed key — and then that key completing a TLS-PSK handshake against
    /// the fleet listener and receiving a snapshot, which is the moment pairing is actually
    /// finished.
    func testATypedCodePairsAndTheDeliveredKeyReachesTheFleet() async throws {
        let (preferences, service) = try await standUp()
        let armed = try await service.arm()
        let port = try armedPort(service)
        XCTAssertEqual(preferences.pairedDevices.first?.isProvisional, true)

        let paired = expectation(description: "paired")
        nonisolated(unsafe) var delivered: FleetDeviceKey?
        nonisolated(unsafe) var deliveredService: String?
        nonisolated(unsafe) var deliveredName: String?
        let runner = PairingRunner()
        self.runner = runner
        runner.onPaired = { key, serviceName, macName in
            MainActor.assumeIsolated {
                delivered = key
                deliveredService = serviceName
                deliveredName = macName
                paired.fulfill()
            }
        }
        runner.onProgress = { progress in
            if case .failed(let failure) = progress { XCTFail("pairing failed: \(failure)") }
            if case .noMacsFound = progress { XCTFail("the armed Mac was not offered") }
        }
        runner.start(code: armed.code, candidates: [
            PairingBrowser.DiscoveredMac(
                serviceName: service.serviceName, displayName: "Test Mac",
                endpoint: .hostPort(host: "127.0.0.1", port: port)
            )
        ])
        await fulfillment(of: [paired], timeout: 30)

        let key = try XCTUnwrap(delivered)
        XCTAssertEqual(key.slot, armed.payload.key.slot)
        XCTAssertEqual(key.secret, armed.payload.key.secret)
        // What a phone stores: the instance name it found the Mac under, and the Mac's own
        // name out of the seal. No endpoints — typed pairing is LAN-only by design (§11) and
        // `FleetConnector` finds the Mac by browsing for this service name.
        XCTAssertEqual(deliveredService, service.serviceName)
        XCTAssertEqual(deliveredName, Host.current().localizedName ?? "Mac")

        // Invariant 2, route 4: success closed the window's listener.
        let stillAnswering = await pairingListenerAnswers(on: port)
        XCTAssertFalse(stillAnswering, "a completed pairing left the pairing listener up")

        // And the delivered key is a real fleet credential, which is the only proof that
        // matters — the seal round-tripping is not the same claim.
        let snapshot = expectation(description: "snapshot")
        let client = FleetClient(key: key, deviceName: "Test Phone")
        self.client = client
        client.onFrame = { if case .snapshot = $0 { snapshot.fulfill() } }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [snapshot], timeout: 15)

        let device = try XCTUnwrap(preferences.pairedDevices.first)
        XCTAssertEqual(device.slot, armed.payload.key.slot)
        XCTAssertFalse(device.isProvisional, "a device that reached the fleet is still provisional")
        XCTAssertNotNil(device.pairedAt)
    }
}
