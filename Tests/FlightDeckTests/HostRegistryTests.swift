import FleetKit
import Foundation
import XCTest
@testable import FlightDeck

@MainActor
final class HostRegistryTests: XCTestCase {
    var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
    }

    override func tearDown() {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for leftover in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where leftover.hasPrefix(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(leftover))
        }
        super.tearDown()
    }

    func testAddPersistsWithoutSecretInFile() throws {
        let secrets = InMemoryHostSecretStore()
        let key = FleetDeviceKey.mint()
        _ = try HostRegistry(fileURL: url, secrets: secrets).add(key: key, name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        let reloaded = HostRegistry(fileURL: url, secrets: secrets)
        XCTAssertEqual(reloaded.hosts.map(\.name), ["mini"])
        XCTAssertEqual(reloaded.hosts.first?.endpoints, ["10.0.0.5:47410"])
        XCTAssertEqual(reloaded.key(for: key.slot), key)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(key.secret.base64EncodedString()))
    }

    /// Review Focus 4.
    func testDuplicateNamesAreDisambiguated() throws {
        let r = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        _ = try r.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: [])
        let second = try r.add(key: .mint(), name: "mini", serviceName: "mini (2)", endpoints: [])
        XCTAssertEqual(second.name, "mini-2")
        XCTAssertEqual(try r.resolve(name: "mini").get().slot, r.hosts[0].slot)
        XCTAssertEqual(r.resolve(name: "maxi"), .failure(.unknown(available: ["mini", "mini-2"])))
    }

    /// The CLI resolves by name alone, so "Mini" must collide with "mini" and resolve to it.
    func testNamesCollideAndResolveCaseInsensitively() throws {
        let r = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        let first = try r.add(key: .mint(), name: "mini", serviceName: "a", endpoints: [])
        _ = try r.add(key: .mint(), name: "mini-2", serviceName: "b", endpoints: [])
        XCTAssertEqual(try r.add(key: .mint(), name: "Mini", serviceName: "c", endpoints: []).name, "Mini-3")
        XCTAssertEqual(try r.resolve(name: "MINI").get().slot, first.slot)
    }

    func testRemoveDeletesSecret() throws {
        let secrets = InMemoryHostSecretStore(); let r = HostRegistry(fileURL: url, secrets: secrets)
        let rec = try r.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: [])
        r.remove(slot: rec.slot)
        XCTAssertNil(secrets.secret(for: rec.slot)); XCTAssertEqual(r.hosts, [])
        XCTAssertEqual(HostRegistry(fileURL: url, secrets: secrets).hosts, [])
    }

    func testUpdatePersistsAndIgnoresAnUnpairedSlot() throws {
        let r = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        var rec = try r.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: [])
        rec.platform = "Linux"
        r.update(rec)
        r.update(HostRecord(slot: UUID(), name: "ghost", serviceName: "g", endpoints: [], platform: nil, pairedAt: Date()))
        let reloaded = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        XCTAssertEqual(reloaded.hosts.map(\.platform), ["Linux"])
    }

    /// An unreadable file is moved aside, not silently treated as empty and then overwritten
    /// by the next pairing.
    func testCorruptFileIsMovedAsideNotOverwritten() throws {
        try Data("{not json".utf8).write(to: url)
        let r = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        XCTAssertEqual(r.hosts, [])
        let directory = url.deletingLastPathComponent().path
        let asides = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasPrefix(url.lastPathComponent + ".corrupt-") }
        XCTAssertEqual(asides.count, 1)
        XCTAssertEqual(try String(contentsOfFile: directory + "/" + asides[0], encoding: .utf8), "{not json")
    }

    /// The one real-Keychain test, under a throwaway service it deletes.
    func testKeychainStoreRoundTripsUnderAThrowawayService() throws {
        let store = KeychainHostSecretStore(service: "dev.flightdeck.host.test-\(UUID().uuidString)")
        let slot = UUID()
        do {
            try store.set(Data([1, 2, 3]), for: slot)
        } catch HostSecretStoreError.keychainWriteFailed(let status) {
            throw XCTSkip("Keychain unavailable here (OSStatus \(status))")
        }
        defer { store.remove(slot: slot) }
        XCTAssertEqual(store.secret(for: slot), Data([1, 2, 3]))
        try store.set(Data([4]), for: slot)
        XCTAssertEqual(store.secret(for: slot), Data([4]))
        store.remove(slot: slot)
        XCTAssertNil(store.secret(for: slot))
    }
}
