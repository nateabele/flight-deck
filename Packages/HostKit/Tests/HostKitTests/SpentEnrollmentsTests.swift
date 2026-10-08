import XCTest
@testable import HostKit

/// The replay guard behind `enroll`: a payload stays valid for `EnrollmentPayload.maxAge`, so
/// "the slot is already in controllers.json" stops a reuse only until someone revokes that slot.
/// The spent list is what still refuses it after a revoke.
final class SpentEnrollmentsTests: XCTestCase {
    var root: URL!
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testASlotCanBeSpentOnce() throws {
        let spent = SpentEnrollments(root: root), slot = UUID()
        XCTAssertTrue(try spent.spend(slot: slot, issuedAt: t0, now: t0))
        XCTAssertFalse(try spent.spend(slot: slot, issuedAt: t0, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(try spent.contains(slot, now: t0.addingTimeInterval(60)))
    }

    /// The point of a file: hostd restarts (a reboot, a crashed `serve`) must not reopen the window.
    func testSpentSurvivesARestart() throws {
        let slot = UUID()
        XCTAssertTrue(try SpentEnrollments(root: root).spend(slot: slot, issuedAt: t0, now: t0))
        XCTAssertFalse(try SpentEnrollments(root: root).spend(slot: slot, issuedAt: t0, now: t0.addingTimeInterval(1)))
    }

    /// Slots are not secrets, but the file says which controllers enrolled when; it lives with
    /// controllers.json and gets the same modes.
    func testFileIsOwnerOnly() throws {
        _ = try SpentEnrollments(root: root).spend(slot: UUID(), issuedAt: t0, now: t0)
        let file = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("enrollments-spent.json").path)
        XCTAssertEqual((file[.posixPermissions] as! NSNumber).intValue & 0o777, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((dir[.posixPermissions] as! NSNumber).intValue & 0o777, 0o700)
    }

    /// Once a payload is past maxAge its own validation refuses it, so its record has nothing
    /// left to guard; without pruning the file would grow by one entry per enroll forever.
    func testEntriesArePrunedOnceTheirPayloadHasExpired() throws {
        let spent = SpentEnrollments(root: root), old = UUID(), fresh = UUID()
        XCTAssertTrue(try spent.spend(slot: old, issuedAt: t0, now: t0))
        let atMaxAge = t0.addingTimeInterval(EnrollmentPayload.maxAge)
        XCTAssertTrue(try spent.spend(slot: fresh, issuedAt: atMaxAge, now: atMaxAge))
        XCTAssertTrue(try spent.contains(old, now: atMaxAge), "still redeemable at exactly maxAge, so still guarded")
        let past = atMaxAge.addingTimeInterval(1)
        XCTAssertTrue(try spent.spend(slot: UUID(), issuedAt: past, now: past))
        let data = try Data(contentsOf: root.appendingPathComponent("enrollments-spent.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(old.uuidString), "pruned from disk")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(fresh.uuidString))
    }

    /// Fail closed: a list that cannot be read cannot prove a slot unspent, and starting empty
    /// would reopen every replay it was holding shut. The bytes stay for whoever investigates.
    func testAnUnreadableListRefusesAndIsLeftInPlace() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("enrollments-spent.json")
        try Data("{not json".utf8).write(to: file)
        XCTAssertThrowsError(try SpentEnrollments(root: root).spend(slot: UUID(), issuedAt: t0, now: t0))
        XCTAssertEqual(try Data(contentsOf: file), Data("{not json".utf8))
    }

    /// The rollback `enroll` uses when storing the controller fails after the slot was spent,
    /// so a disk error does not burn the machine's only enrollment file.
    func testForgetReleasesASlot() throws {
        let spent = SpentEnrollments(root: root), slot = UUID()
        XCTAssertTrue(try spent.spend(slot: slot, issuedAt: t0, now: t0))
        try spent.forget(slot)
        XCTAssertTrue(try spent.spend(slot: slot, issuedAt: t0, now: t0))
    }
}
