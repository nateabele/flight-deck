import XCTest
@testable import FleetKit

final class TimelineSpillStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWriteThenReadRoundTripsTheBodies() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineSpillStore(session: UUID(), directory: dir)
        let bodies = [
            "0#0": TimelineItem.Body(text: "full body one", callID: "tA"),
            "10#0": TimelineItem.Body(text: "full body two"),
        ]
        store.write(bodies)
        let read = store.read(["0#0", "10#0"])
        XCTAssertEqual(read["0#0"]?.text, "full body one")
        XCTAssertEqual(read["0#0"]?.callID, "tA")
        XCTAssertEqual(read["10#0"]?.text, "full body two")
    }

    func testWriteAppendsRatherThanReplacingTheWholeFile() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineSpillStore(session: UUID(), directory: dir)
        store.write(["0#0": TimelineItem.Body(text: "one")])
        store.write(["10#0": TimelineItem.Body(text: "two")])
        let read = store.read(["0#0", "10#0"])
        XCTAssertEqual(read.count, 2, "a second write does not lose the first record")
    }

    /// A purged cache (the OS may drop a Caches file under pressure) reads empty — the model's
    /// wire-refetch fallback covers it.
    func testReadingAPurgedStoreReturnsEmpty() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineSpillStore(session: UUID(), directory: dir)
        store.write(["0#0": TimelineItem.Body(text: "one")])
        store.purge()
        XCTAssertTrue(store.read(["0#0"]).isEmpty)
    }
}
