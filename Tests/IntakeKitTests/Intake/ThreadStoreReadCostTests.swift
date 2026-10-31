import XCTest
@testable import IntakeKit

/// What the Mac panel's poll costs (Stream C reads `ThreadStoreReading` every 0.5–2 s on the
/// main actor, for every thread): 20 threads of 50 turns each, read 200 times.
final class ThreadStoreReadCostTests: XCTestCase {
    private var root: URL!
    private var ids: [ThreadID] = []
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-thread-cost-\(UUID().uuidString)")
        let store = ThreadStore(intakeDirectory: root)
        ids = (0..<20).map { _ in ThreadID() }
        for (n, id) in ids.enumerated() {
            try store.save(ThreadRecord(id: id, title: "Thread \(n)", anchor: .wholePlan,
                                        status: n % 4 == 0 ? .resolved : .open, agent: .claude, model: "m", effort: "high",
                                        followsCheckpoint: 1, createdAt: created.addingTimeInterval(TimeInterval(n))))
            let turns = (1...50).map { seq in
                ThreadTurn(seq: seq, messageID: "m\(seq)", you: String(repeating: "question words ", count: 20),
                           reply: String(repeating: "a reply with [cite:cp1.v3] in it ", count: 40), decision: "Decided.",
                           checkpoint: 1, startedAt: created, endedAt: created)
            }
            try store.save(turns: turns, of: id)
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// One poll: every thread, and every thread's turns, as the panel's index and cards read them.
    private func poll(_ store: ThreadStore) -> Int {
        var n = store.threads().count
        for id in ids { n += store.turns(id).count + store.diffs(id).count }
        return n
    }

    func testTwoHundredPollsOfTwentyThreads() {
        let store = ThreadStore(intakeDirectory: root)
        let clock = ContinuousClock()
        var total = 0
        let first = clock.measure { total += poll(store) }
        let rest = clock.measure { for _ in 1..<200 { total += poll(store) } }
        XCTAssertEqual(total, 200 * (20 + 20 * 50))
        let perPoll = rest / 199
        print("ThreadStoreReadCost: first poll \(first), then \(perPoll) per poll (200 polls: \(first + rest))")
        // Uncached, a poll was 0.41 s on the dev Mac; the bound is loose so a slow host passes,
        // and tight enough that losing the cache fails.
        XCTAssertLessThan(perPoll, .milliseconds(40))
    }

    /// The cache never hides a write: a reader sees what another process's store wrote, even a
    /// change that keeps the file's size.
    func testAReaderSeesEveryWrite() throws {
        let reader = ThreadStore(intakeDirectory: root), writer = ThreadStore(intakeDirectory: root)
        let id = ids[1]
        XCTAssertEqual(reader.thread(id)?.title, "Thread 1")
        var record = try XCTUnwrap(writer.thread(id))
        record.title = "Thread X"
        try writer.save(record)
        XCTAssertEqual(reader.thread(id)?.title, "Thread X", "same size, new file")

        var turns = writer.turns(id)
        turns[49].reply = "changed"
        try writer.save(turns: turns, of: id)
        XCTAssertEqual(reader.turns(id).last?.reply, "changed")

        let diff = ThreadDiff(thread: id, turn: 50, checkpoint: 1, anchor: NoteAnchor(checkpoint: 1, quote: "q"), old: "q", new: "r")
        try writer.save(diff)
        XCTAssertEqual(reader.diffs(id).map(\.state), [.pending])
        var accepted = diff
        accepted.state = .stale
        try writer.save(accepted)
        XCTAssertEqual(reader.diff(id, diff.id)?.state, .stale)

        let fresh = ThreadID()
        try writer.save(ThreadRecord(id: fresh, title: "New", anchor: .wholePlan, agent: .codex, model: "m", effort: "",
                                     followsCheckpoint: 1, createdAt: created.addingTimeInterval(100)))
        XCTAssertEqual(reader.threads().last?.id, fresh)
    }

    /// The fingerprint holds while nothing changes and moves on any write a reader would show.
    func testFingerprintMovesOnlyOnAWrite() throws {
        let store = ThreadStore(intakeDirectory: root)
        let before = store.fingerprint()
        XCTAssertEqual(store.fingerprint(), before)
        var turns = store.turns(ids[3])
        turns[0].decision = "Other."
        try store.save(turns: turns, of: ids[3])
        let afterTurns = store.fingerprint()
        XCTAssertNotEqual(afterTurns, before)
        try store.save(ThreadDiff(thread: ids[0], checkpoint: 1, anchor: NoteAnchor(checkpoint: 1, quote: "q"), old: "q", new: "r"))
        XCTAssertNotEqual(store.fingerprint(), afterTurns)
    }
}
