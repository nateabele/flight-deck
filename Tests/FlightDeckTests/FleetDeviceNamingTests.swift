import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// What the Devices list ends up calling a paired phone.
///
/// The bug this file exists for: every paired device was listed as the literal string
/// "New device", forever. Nothing was losing the name — `hello` never carried one, so the
/// Mac had nothing to display but the placeholder `PairingArmer` minted.
///
/// These drive a real listener and a real `FleetClient` rather than calling
/// `PreferencesStore` directly, because the claim has to survive the whole path — wire
/// field, attachment, `noteAttached` — and the layer that broke it before was the one in
/// the middle. `@MainActor` with `await fulfillment(of:)`, never `wait(for:)`: the
/// listener's queue is `.main`, and blocking it starves the callbacks being waited on.
@MainActor
final class FleetDeviceNamingTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private var service: FleetService?
    private var clients: [FleetClient] = []
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func tearDown() async throws {
        for client in clients { client.disconnect() }
        clients.removeAll()
        service?.stop()
        service = nil
    }

    private func standUp() async throws -> (PreferencesStore, FleetService) {
        let preferences = PreferencesStore(persistence: MemoryPersistence())
        let service = FleetService(
            store: SessionStore(provider: nil, persistence: nil),
            preferences: preferences,
            armer: PairingArmer(now: { self.now })
        )
        self.service = service
        _ = try await service.start(port: nil)
        return (preferences, service)
    }

    /// Connects a client claiming `deviceName` and returns once the Mac has answered its
    /// `hello` — the snapshot is the only signal that `noteAttached` has already run, so
    /// waiting on it is what makes the assertions after it deterministic rather than racy.
    @discardableResult
    private func attach(
        _ key: FleetDeviceKey, claiming deviceName: String?, to service: FleetService
    ) async throws -> FleetClient {
        let answered = expectation(description: "hello answered for \(deviceName ?? "no name")")
        let client = FleetClient(key: key, deviceName: deviceName)
        clients.append(client)
        client.onFrame = { if case .snapshot = $0 { answered.fulfill() } }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 10)
        return client
    }

    /// The headline: a device that says what it is called is listed under that name, from
    /// the very first attach — which is the same instant pairing completes.
    func testADeviceThatNamesItselfIsListedUnderThatName() async throws {
        let (preferences, service) = try await standUp()
        let payload = try await service.arm()

        try await attach(payload.key, claiming: "Nate's iPhone", to: service)

        let device = try XCTUnwrap(preferences.pairedDevices.first)
        XCTAssertEqual(
            device.name, "Nate's iPhone",
            "a device that named itself is still being listed under the placeholder"
        )
        XCTAssertFalse(device.isProvisional, "the same attach also completes pairing")
    }

    /// The claim is optional on the wire, so the placeholder has to remain a real fallback
    /// rather than something the adoption path assumes away.
    func testADeviceThatClaimsNoNameKeepsThePlaceholder() async throws {
        let (preferences, service) = try await standUp()
        let payload = try await service.arm()

        try await attach(payload.key, claiming: nil, to: service)

        XCTAssertEqual(preferences.pairedDevices.first?.name, "New device")
    }

    /// Adoption is not a one-shot at pairing. Renaming the phone in iOS Settings must show
    /// up here, which means every attach re-adopts rather than only the first.
    func testRenamingThePhoneItselfShowsUpOnTheNextAttach() async throws {
        let (preferences, service) = try await standUp()
        let payload = try await service.arm()

        let first = try await attach(payload.key, claiming: "iPhone", to: service)
        XCTAssertEqual(preferences.pairedDevices.first?.name, "iPhone")
        first.disconnect()

        try await attach(payload.key, claiming: "Nate's iPhone", to: service)
        XCTAssertEqual(preferences.pairedDevices.first?.name, "Nate's iPhone")
    }

    /// And the limit on that. `UIDevice.current.name` hands back "iPhone" for an app without
    /// the user-assigned-device-name entitlement, so two phones arrive claiming the same
    /// thing and the user has to rename one here. A rename that the next reconnect undoes is
    /// not a rename.
    func testANameTheUserChoseSurvivesALaterAttach() async throws {
        let (preferences, service) = try await standUp()
        let payload = try await service.arm()

        let first = try await attach(payload.key, claiming: "iPhone", to: service)
        preferences.renameDevice(slot: payload.key.slot, to: "Work phone")
        first.disconnect()

        try await attach(payload.key, claiming: "iPhone", to: service)

        let device = try XCTUnwrap(preferences.pairedDevices.first)
        XCTAssertEqual(
            device.name, "Work phone",
            "a later hello clobbered the name the user chose on the Mac"
        )
        XCTAssertTrue(device.isUserNamed)
    }
}
