import XCTest
@testable import FlightDeck

/// The fixture path exists so a screenshot run can pose a deck it could never reach through
/// the UI — several projects, sessions in every status, unread marks. It reads state from a
/// directory handed to it on the command line and, critically, writes nothing anywhere.
///
/// That last part is the whole point of these tests. `FileSessionPersistence` writes to
/// `~/Library/Application Support/Flight Deck/sessions.json`, which holds the developer's
/// real deck. A fixture run that saved would overwrite it with a posed one. `save` being a
/// no-op is a load-bearing behaviour, not an omission, so it is tested directly.
@MainActor
final class SessionFixtureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writeSnapshot(_ snapshot: SessionSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: root.appendingPathComponent("sessions.json"))
    }

    func testLoadsTheSnapshotItWasPointedAt() throws {
        let id = UUID()
        try writeSnapshot(SessionSnapshot(
            sessions: [.init(id: id, title: "posed", workingDirectory: "/w")],
            selectedSessionID: id,
            sessionCounter: 1
        ))

        let loaded = SessionFixture(root: root).persistence().load()

        XCTAssertEqual(loaded?.sessions.count, 1)
        XCTAssertEqual(loaded?.sessions.first?.title, "posed")
        XCTAssertEqual(loaded?.selectedSessionID, id)
    }

    /// The guarantee the whole fixture path rests on: a save must not reach the disk, and in
    /// particular must not touch the file the fixture was loaded from.
    func testSaveWritesNothingAndLeavesTheFixtureByteIdentical() throws {
        let id = UUID()
        try writeSnapshot(SessionSnapshot(
            sessions: [.init(id: id, title: "posed", workingDirectory: "/w")],
            selectedSessionID: id,
            sessionCounter: 1
        ))
        let file = root.appendingPathComponent("sessions.json")
        let before = try Data(contentsOf: file)
        let namesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))

        let persistence = SessionFixture(root: root).persistence()
        persistence.save(SessionSnapshot(
            sessions: [.init(id: UUID(), title: "mutated", workingDirectory: "/other")],
            selectedSessionID: nil,
            sessionCounter: 99
        ))

        XCTAssertEqual(try Data(contentsOf: file), before, "the fixture file was rewritten")
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
            namesBefore,
            "saving created a file"
        )
        // And it still reads back as the posed deck, not the saved one.
        XCTAssertEqual(persistence.load()?.sessions.first?.title, "posed")
    }

    /// A missing or malformed fixture reports "nothing to restore" so the store seeds its
    /// normal initial session, rather than trapping on launch.
    func testAbsentFixtureLoadsNothing() {
        XCTAssertNil(
            SessionFixture(root: root.appendingPathComponent("nope")).persistence().load()
        )
    }

    func testMalformedFixtureLoadsNothing() throws {
        try Data("{not json".utf8).write(to: root.appendingPathComponent("sessions.json"))

        XCTAssertNil(SessionFixture(root: root).persistence().load())
    }

    /// The layout is a contract shared with `ScreenshotTests`, which writes the directory
    /// this reads. Pinning it here means a rename breaks a unit test rather than silently
    /// producing a screenshot of an empty deck.
    func testDirectoryLayout() {
        let fixture = SessionFixture(root: URL(fileURLWithPath: "/tmp/f"))

        XCTAssertEqual(fixture.snapshotURL.path, "/tmp/f/sessions.json")
        XCTAssertEqual(fixture.statusRoot.path, "/tmp/f/status")
        XCTAssertEqual(fixture.projectsRoot.path, "/tmp/f/projects")
        XCTAssertEqual(fixture.shellURL.path, "/tmp/f/shell")
    }
}
