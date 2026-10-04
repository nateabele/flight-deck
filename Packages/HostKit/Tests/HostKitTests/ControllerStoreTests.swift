import XCTest
@testable import HostKit

final class ControllerStoreTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testAddPersistsAndReloads() throws {
        let c = PairedController(slot: UUID(), name: "laptop", secret: PortableRandom.bytes(32), pairedAt: Date())
        try ControllerStore(root: root).add(c)
        XCTAssertEqual(ControllerStore(root: root).all(), [c])
    }

    /// Secrets on disk must not be readable by other users of the host.
    func testFileIsOwnerOnly() throws {
        try ControllerStore(root: root).add(.init(slot: UUID(), name: "x", secret: PortableRandom.bytes(32), pairedAt: Date()))
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("controllers.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as! NSNumber).intValue & 0o777, 0o600)
    }

    func testRevokeRemovesAndNotifies() throws {
        let store = ControllerStore(root: root); let slot = UUID()
        try store.add(.init(slot: slot, name: "x", secret: PortableRandom.bytes(32), pairedAt: Date()))
        let fired = expectation(description: "onChange"); store.onChange = { fired.fulfill() }
        XCTAssertTrue(try store.revoke(slot: slot))
        wait(for: [fired], timeout: 1)
        XCTAssertEqual(store.all(), [])
        XCTAssertFalse(try store.revoke(slot: slot))
    }
}
