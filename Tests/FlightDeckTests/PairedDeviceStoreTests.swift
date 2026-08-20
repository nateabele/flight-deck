import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class PairedDeviceStoreTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private func device(_ name: String) -> PairedDevice {
        let key = FleetDeviceKey.mint()
        return PairedDevice(
            slot: key.slot, name: name, secret: key.secret,
            pairedAt: Date(), lastSeenAt: nil, armedUntil: nil
        )
    }

    func testADeviceSurvivesASaveAndReload() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        let phone = device("Nate's iPhone")
        store.upsert(phone)

        let reloaded = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reloaded.pairedDevices, [phone])
    }

    /// Revocation is deleting the secret, and this is the assertion that says so: the key is
    /// gone from what the listener will be started with, not merely hidden from a list.
    func testRevokingRemovesTheKeyTheListenerWouldAccept() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        let phone = device("phone")
        let tablet = device("tablet")
        store.upsert(phone)
        store.upsert(tablet)
        store.revokeDevice(slot: phone.slot)
        XCTAssertEqual(store.deviceKeys().map(\.slot), [tablet.slot])
    }

    func testUpsertingTheSameSlotReplacesRatherThanDuplicates() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        var phone = device("phone")
        store.upsert(phone)
        phone.name = "renamed"
        store.upsert(phone)
        XCTAssertEqual(store.pairedDevices.count, 1)
        XCTAssertEqual(store.pairedDevices.first?.name, "renamed")
    }

    func testRenamingAndNotingASightingDoNotDisturbTheSecret() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        let phone = device("phone")
        store.upsert(phone)
        store.renameDevice(slot: phone.slot, to: "Nate's iPhone")
        let seen = Date(timeIntervalSince1970: 2_000_000)
        store.noteDeviceSeen(slot: phone.slot, at: seen)
        XCTAssertEqual(store.pairedDevices.first?.name, "Nate's iPhone")
        XCTAssertEqual(store.pairedDevices.first?.lastSeenAt, seen)
        XCTAssertEqual(store.pairedDevices.first?.secret, phone.secret)
    }

    /// The rule every field in `Preferences` obeys: a blob written before this feature
    /// existed must still decode, or the first launch after an upgrade silently resets every
    /// flag, override and shell setting the user has.
    ///
    /// The brief's literal JSON used `"globalFlags":{"flags":[]}`, which does not match
    /// `FlagSet`'s actual `Codable` shape (`values`/`passthrough`) and would fail to decode
    /// for a reason unrelated to this test's point. Built from an encoded empty
    /// `Preferences()` instead, with `pairedDevices` stripped out, so the fixture always
    /// tracks the real wire shape.
    func testAPreferencesBlobWithNoPairedDevicesKeyStillDecodes() throws {
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Preferences())
        ) as! [String: Any]
        object.removeValue(forKey: "pairedDevices")
        let json = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertNil(decoded.pairedDevices)
    }

    func testNoDevicesMeansNoKeysRatherThanACrash() {
        XCTAssertTrue(PreferencesStore(persistence: MemoryPersistence()).deviceKeys().isEmpty)
    }

    /// The Bonjour instance name has to survive a relaunch, or a phone that remembers which
    /// Mac it paired with stops recognising it after a restart.
    func testTheInstallSuffixIsMintedOnceAndThenStable() {
        let persistence = MemoryPersistence()
        let first = PreferencesStore(persistence: persistence).installSuffix
        XCTAssertEqual(first.count, 4)
        XCTAssertEqual(PreferencesStore(persistence: persistence).installSuffix, first)
    }

    func testTwoInstallsDoNotShareASuffix() {
        XCTAssertNotEqual(
            PreferencesStore(persistence: MemoryPersistence()).installSuffix,
            PreferencesStore(persistence: MemoryPersistence()).installSuffix
        )
    }
}
