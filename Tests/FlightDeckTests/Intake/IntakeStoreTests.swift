import XCTest
import IntakeKit

final class IntakeStoreTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("intakes-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testSaveLoadRoundTrip() throws {
        let store = IntakeStore(root: root)
        var i = Intake(projectPath: "/p", intent: "add a tooltip")
        i.state = .needsAnswers
        i.exchanges = [TriageExchange(questions: ["Mac only?"], answers: nil)]
        try store.save(i)
        XCTAssertEqual(try store.load(id: i.id), i)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: i.id).appendingPathComponent("intake.json").path))
    }
    func testAllSkipsCorruptFilesAndSortsNewestFirst() throws {
        let store = IntakeStore(root: root)
        let a = Intake(projectPath: "/p", intent: "a", createdAt: Date(timeIntervalSince1970: 1))
        let b = Intake(projectPath: "/p", intent: "b", createdAt: Date(timeIntervalSince1970: 2))
        try store.save(a); try store.save(b)
        let bad = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad.appendingPathComponent("intake.json"))
        XCTAssertEqual(store.all().map(\.intent), ["b", "a"])
    }
    func testAttentionStates() {
        XCTAssertTrue(IntakeState.needsAnswers.needsAttention)
        XCTAssertTrue(IntakeState.review.needsAttention)
        XCTAssertTrue(IntakeState.failed.needsAttention)
        XCTAssertFalse(IntakeState.triaging.needsAttention)
        XCTAssertFalse(IntakeState.released.needsAttention)
    }
    func testRoundTripWithExplicitDate() throws {
        let store = IntakeStore(root: root)
        let fixedDate = Date(timeIntervalSince1970: 1000)
        var i = Intake(projectPath: "/p", intent: "test", createdAt: fixedDate)
        i.state = .review
        i.ratingOverrides = [1: .clarifying, 2: .scopeChange]
        i.droppedOps = [5, 3, 1]
        i.confirmedDrift = [7, 2]
        try store.save(i)
        let loaded = try store.load(id: i.id)
        XCTAssertEqual(loaded, i)
        XCTAssertEqual(loaded.ratingOverrides, [1: .clarifying, 2: .scopeChange])
        XCTAssertEqual(loaded.droppedOps, [5, 3, 1])
        XCTAssertEqual(loaded.confirmedDrift, [7, 2])
    }
}
