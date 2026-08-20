import XCTest
import FleetKit

final class PairedMacStoreTests: XCTestCase {
    private func payload() -> PairingPayload {
        PairingPayload(
            key: .mint(), macName: "Nate's MacBook Pro", serviceName: "flightdeck-a1b2",
            endpoints: ["192.168.1.20:53211", "127.0.0.1:53211"]
        )
    }

    func testAdoptingAPayloadKeepsEverythingNeededToReconnect() {
        let payload = payload()
        let mac = PairedMac(adopting: payload)
        XCTAssertEqual(mac.key, payload.key)
        XCTAssertEqual(mac.macName, payload.macName)
        XCTAssertEqual(mac.serviceName, payload.serviceName)
        XCTAssertEqual(mac.endpoints, payload.endpoints)
        XCTAssertEqual(mac.lastSeq, 0, "a freshly paired phone has applied nothing")
    }

    func testTheRecordRoundTripsThroughItsCodableForm() throws {
        var mac = PairedMac(adopting: payload())
        mac.lastSeq = 812
        let data = try JSONEncoder().encode(mac)
        XCTAssertEqual(try JSONDecoder().decode(PairedMac.self, from: data), mac)
    }

    /// `FleetDeviceKey` is deliberately not `Codable`, so `PairedMac` carries its own manual
    /// conformance with the secret as an explicit base64url string (see `PairedMac.swift`).
    /// A record whose secret has been corrupted to something that is not valid base64url
    /// must fail to decode, not decode to an empty or truncated key that would silently
    /// authenticate against nothing.
    func testACorruptedSecretFailsToDecodeRatherThanProducingGarbage() throws {
        let mac = PairedMac(adopting: payload())
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(mac)
        ) as! [String: Any]
        object["secret"] = "not valid base64url! @#$"
        let json = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(PairedMac.self, from: json))
    }

    func testSavingReplacesRatherThanAccumulating() {
        let store = InMemoryPairedMacStore()
        store.save(PairedMac(adopting: payload()))
        let second = PairedMac(adopting: payload())
        store.save(second)
        XCTAssertEqual(store.load(), second)
    }

    /// Unpairing on the phone must destroy the secret, not merely stop showing the fleet.
    func testClearingDestroysTheRecord() {
        let store = InMemoryPairedMacStore()
        store.save(PairedMac(adopting: payload()))
        store.clear()
        XCTAssertNil(store.load())
    }

    /// The two attributes that keep the secret on one device. Asserted against the query the
    /// store builds rather than against the Keychain itself, because a test bundle cannot
    /// reach the app's keychain — the live path is verified by hand in Task 11.
    func testTheKeychainQueryRefusesToSyncOrTravel() {
        let query = KeychainPairedMacStore.attributes(for: Data())
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }
}
