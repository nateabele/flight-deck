import XCTest
import IntakeKit

/// `TapeStore.appendCommand(composing:)`: read, compose and append as one step under the
/// commands lock, for a command built from what is already queued (an auto-accepted diff).
final class TapeStoreComposingAppendTests: XCTestCase {
    private var store: TapeStore!

    override func setUp() {
        store = TapeStore(intakeDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-compose-\(UUID().uuidString)"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: store.intakeDirectory) }

    func testTheComposerSeesEveryQueuedCommandAndItsCommandLandsNext() throws {
        try store.appendCommand(.editPlan(checkpoint: 1, markdown: "X"))
        try store.appendCommand(.pause)
        var seen: [Int] = []
        let seq = try store.appendCommand(composing: { current in
            seen = current.map(\.seq)
            guard case .editPlan(_, let markdown) = current.first?.command else { return nil }
            return .editPlan(checkpoint: 1, markdown: markdown + " and more")
        })
        XCTAssertEqual(seen, [1, 2])
        XCTAssertEqual(seq, 3)
        XCTAssertEqual(store.commands(after: 2).map(\.command), [.editPlan(checkpoint: 1, markdown: "X and more")])
    }

    func testAComposerThatDeclinesAppendsNothing() throws {
        try store.appendCommand(.pause)
        XCTAssertNil(try store.appendCommand(composing: { _ in nil }))
        XCTAssertEqual(store.commands(after: 0).count, 1)
    }

    /// A plain append from another thread waits for the composer instead of landing between its
    /// read and its write.
    func testAPlainAppendCannotLandBetweenTheReadAndTheAppend() throws {
        let other = store!
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var composedOn: [Int] = []
        DispatchQueue.global().async {
            _ = try? other.appendCommand(composing: { current in
                started.signal()
                Thread.sleep(forTimeInterval: 0.2)
                composedOn = current.map(\.seq)
                return .stop
            })
            done.signal()
        }
        started.wait()
        try store.appendCommand(.pause) // blocks until the composer's append is down
        done.wait()
        XCTAssertEqual(composedOn, [])
        XCTAssertEqual(store.commands(after: 0).map(\.command), [.stop, .pause])
    }
}
