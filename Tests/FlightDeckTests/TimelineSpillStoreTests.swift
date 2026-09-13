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

    /// `write` is dispatched with `queue.async`, not `queue.sync` — see its own doc comment for
    /// why. This is the reasoning that makes that safe, pinned as a test: a `read` issued right
    /// after, on the same instance, still finds the write's result rather than racing it, because
    /// `queue` is serial and the read is enqueued behind the write.
    func testAReadRightAfterAnAsyncWriteStillObservesIt() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineSpillStore(session: UUID(), directory: dir)
        store.write(["0#0": TimelineItem.Body(text: "one")])
        store.write(["10#0": TimelineItem.Body(text: "two")])
        let read = store.read(["0#0", "10#0"])
        XCTAssertEqual(read["0#0"]?.text, "one",
                       "the sync read blocks until the async write ahead of it on the same queue completes")
        XCTAssertEqual(read["10#0"]?.text, "two")
    }

    /// A rehydrated body's id is pruned from the store so the file tracks the currently-spilled
    /// set rather than growing across the whole session — see `SessionTimelineModel.reconcileSpill`.
    func testRemoveDropsOnlyTheNamedIdsAndKeepsTheRest() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineSpillStore(session: UUID(), directory: dir)
        store.write([
            "0#0": TimelineItem.Body(text: "one"),
            "10#0": TimelineItem.Body(text: "two"),
            "20#0": TimelineItem.Body(text: "three"),
        ])

        store.remove(["10#0"])

        let read = store.read(["0#0", "10#0", "20#0"])
        XCTAssertEqual(read["0#0"]?.text, "one", "an id not named survives")
        XCTAssertNil(read["10#0"], "the named id is gone")
        XCTAssertEqual(read["20#0"]?.text, "three", "so does the other survivor")
    }

    /// `purgeAll` clears the whole spill directory, every session's file at once — what
    /// `FleetModel.unpair()` calls so a revoked pairing leaves no spilled transcript behind.
    func testPurgeAllRemovesEverySessionsFileInTheDirectory() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sessionA = UUID()
        let sessionB = UUID()
        let storeA = TimelineSpillStore(session: sessionA, directory: dir)
        let storeB = TimelineSpillStore(session: sessionB, directory: dir)
        storeA.write(["0#0": TimelineItem.Body(text: "a")])
        storeB.write(["0#0": TimelineItem.Body(text: "b")])
        XCTAssertFalse(storeA.read(["0#0"]).isEmpty, "the premise: both sessions have spilled")
        XCTAssertFalse(storeB.read(["0#0"]).isEmpty)

        TimelineSpillStore.purgeAll(directory: dir)

        XCTAssertTrue(TimelineSpillStore(session: sessionA, directory: dir).read(["0#0"]).isEmpty)
        XCTAssertTrue(TimelineSpillStore(session: sessionB, directory: dir).read(["0#0"]).isEmpty)
    }
}
