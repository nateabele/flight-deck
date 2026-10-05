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

    /// A file that will not decode must not be silently replaced by the next add.
    func testCorruptFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let garbage = Data("{not json, but precious".utf8)
        try garbage.write(to: root.appendingPathComponent("controllers.json"))
        let store = ControllerStore(root: root)
        XCTAssertEqual(store.all(), [])
        try store.add(.init(slot: UUID(), name: "x", secret: PortableRandom.bytes(32), pairedAt: Date()))
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("controllers.json.corrupt-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(aside[0])), garbage)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(aside[0]).path)
        XCTAssertEqual((attrs[.posixPermissions] as! NSNumber).intValue & 0o777, 0o600)
    }

    /// A store opened while another store on the same root writes its first controller must
    /// see the file or nothing, never move it aside. Deciding "missing" by a second
    /// `fileExists` look after the failed read raced that write: the read missed the file, the
    /// write's rename landed, and the reader renamed the fresh controllers.json to a
    /// `corrupt-` file — seen live in the macOS hostd's loopback tests under load.
    func testAReaderRacingTheFirstWriteNeverMovesItAside() throws {
        for round in 0..<200 {
            let dir = root.appendingPathComponent("r\(round)")
            let writer = Thread {
                try? ControllerStore(root: dir).add(.init(slot: UUID(), name: "x",
                                                          secret: PortableRandom.bytes(32), pairedAt: Date()))
            }
            writer.start()
            let deadline = Date().addingTimeInterval(1)
            while ControllerStore(root: dir).all().isEmpty, Date() < deadline {}
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            XCTAssertFalse(names.contains { $0.hasPrefix("controllers.json.corrupt-") },
                           "round \(round): a racing reader moved the fresh file aside")
            XCTAssertTrue(names.contains("controllers.json"), "round \(round)")
        }
    }

    func testOnlyAMissingFileReadsAsMissing() throws {
        let missing = root.appendingPathComponent("nope.json")
        XCTAssertThrowsError(try Data(contentsOf: missing)) {
            XCTAssertTrue(ControllerStore.isMissingFile($0))
        }
        XCTAssertFalse(ControllerStore.isMissingFile(CocoaError(.fileReadCorruptFile)))
        XCTAssertFalse(ControllerStore.isMissingFile(DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "x"))))
    }

    /// A root that pre-exists with a wider mode (created by something else) is tightened.
    func testExistingRootIsTightenedTo0700() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try ControllerStore(root: root).add(.init(slot: UUID(), name: "x", secret: PortableRandom.bytes(32), pairedAt: Date()))
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attrs[.posixPermissions] as! NSNumber).intValue & 0o777, 0o700)
    }

    func testRenameUpdatesPersistsAndNotifies() throws {
        let store = ControllerStore(root: root); let slot = UUID()
        try store.add(.init(slot: slot, name: "old", secret: PortableRandom.bytes(32), pairedAt: Date()))
        let fired = expectation(description: "onChange"); store.onChange = { fired.fulfill() }
        XCTAssertTrue(try store.rename(slot: slot, to: "new"))
        wait(for: [fired], timeout: 1)
        XCTAssertEqual(ControllerStore(root: root).all().first?.name, "new")
        XCTAssertFalse(try store.rename(slot: UUID(), to: "z"))
    }
}
