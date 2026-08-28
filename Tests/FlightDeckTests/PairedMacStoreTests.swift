import Security
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

    /// The regression this file exists to pin from now on.
    ///
    /// `KeychainPairedMacStore.save` used to `assertionFailure` on any unexpected `OSStatus`,
    /// which is the worst of both endings: in debug it killed the app (twice, on an unsigned
    /// simulator build with no keychain access group — `errSecMissingEntitlement`, -34018),
    /// and in release `assertionFailure` compiles out, so the write silently did nothing and
    /// the user paired, saw success, and lost the pairing on the next launch. Neither ending
    /// is observable by a caller, which is precisely the problem: the failure has to be able
    /// to REACH the pairing screen.
    ///
    /// Asserted through `any PairedMacStoring`, because that is how `FleetModel` holds its
    /// store — a failure that propagates through the concrete type but not the existential
    /// would not reach the UI.
    func testAFailingSaveIsReportedToTheCallerRatherThanSwallowed() {
        let store: any PairedMacStoring = FailingPairedMacStore(
            error: .keychainWriteFailed(status: errSecMissingEntitlement)
        )
        XCTAssertThrowsError(try store.save(PairedMac(adopting: payload()))) { error in
            XCTAssertEqual(
                error as? PairedMacStoreError,
                .keychainWriteFailed(status: errSecMissingEntitlement),
                "the status is the whole diagnosis — -34018 is an unsigned build, not a broken device"
            )
        }
        XCTAssertNil(store.load(), "a save that threw must not leave a record behind")
    }

    /// The in-memory store is the other half of the protocol and must stay usable without
    /// ceremony: it cannot fail, so it never throws, and a non-throwing method witnesses the
    /// throwing requirement. This pins that it is still callable without `try` on the
    /// concrete type, which is what keeps the existing tests and fixtures readable.
    func testTheInMemoryStoreNeverFails() {
        let store = InMemoryPairedMacStore()
        let mac = PairedMac(adopting: payload())
        store.save(mac)
        XCTAssertEqual(store.load(), mac)
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

/// A store that cannot write, standing in for the keychain refusing one — which is not
/// reproducible in a test bundle, since a test bundle cannot reach the app's keychain at all
/// (see `testTheKeychainQueryRefusesToSyncOrTravel` for the same limitation).
private final class FailingPairedMacStore: PairedMacStoring {
    private let error: PairedMacStoreError

    init(error: PairedMacStoreError) { self.error = error }

    func load() -> PairedMac? { nil }

    func save(_ mac: PairedMac) throws { throw error }

    func clear() {}
}
