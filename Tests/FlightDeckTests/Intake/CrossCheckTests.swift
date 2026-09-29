import XCTest
import IntakeKit

/// The pieces a cross-check round stores and hands the integrator (coverage spec §4).
final class CrossCheckTests: XCTestCase {
    private func changes(_ tag: String, _ n: Int) -> [ProposedChange] {
        (0..<n).map { ProposedChange(section: "## S", rationale: "\(tag)\($0)", edit: "e") }
    }

    func testInterleaveKeepsEveryProposalAndRecordsItsProposer() {
        let (merged, proposers) = BlindOrder.interleave(changes("a", 3), changes("b", 2), seed: 7)
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(proposers.filter { $0 == 0 }.count, 3)
        XCTAssertEqual(proposers.filter { $0 == 1 }.count, 2)
        for (change, p) in zip(merged, proposers) { XCTAssertTrue(change.rationale.hasPrefix(p == 0 ? "a" : "b")) }
    }

    /// A retried round must hand the integrator the same order (Review Focus 4).
    func testInterleaveIsDeterministicPerSeedAndVariesAcrossSeeds() {
        let a = BlindOrder.interleave(changes("a", 6), changes("b", 6), seed: 3)
        XCTAssertEqual(a.proposers, BlindOrder.interleave(changes("a", 6), changes("b", 6), seed: 3).proposers)
        XCTAssertNotEqual(a.proposers, BlindOrder.interleave(changes("a", 6), changes("b", 6), seed: 4).proposers)
        // Blind means not grouped: A's proposals must not simply all come first.
        XCTAssertNotEqual(a.proposers, [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1])
    }

    func testInterleaveWithAnEmptySide() {
        XCTAssertEqual(BlindOrder.interleave([], changes("b", 2), seed: 1).proposers, [1, 1])
        XCTAssertEqual(BlindOrder.interleave([], [], seed: 1).changes, [])
    }

    /// Review Focus 2: junk clusters clean to a valid partition's non-singletons, or nil.
    func testCleaningClusters() {
        XCTAssertEqual(IssueClusters.clean([[0, 3], [1, 9], [3, 2], [4]], count: 5), [[0, 3]])
        XCTAssertEqual(IssueClusters.clean([[2, 1, 1]], count: 3), [[1, 2]])
        XCTAssertNil(IssueClusters.clean([], count: 3))
        XCTAssertNil(IssueClusters.clean(nil, count: 3))
        XCTAssertNil(IssueClusters.clean([[7, 8]], count: 3))
    }

    func testPartitionAddsSingletons() {
        XCTAssertEqual(IssueClusters.partition([[0, 3]], count: 5), [[0, 3], [1], [2], [4]])
        XCTAssertEqual(IssueClusters.partition(nil, count: 2), [[0], [1]])
    }

    func testRecordRoundTrips() throws {
        let r = CrossCheckRecord(proposers: [0, 1], families: [.codex, .claude], clusters: nil, blindOrderSeed: 4)
        let data = try IntakeJSON.encoder.encode(r)
        XCTAssertEqual(try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: data), r)
        XCTAssertEqual(CrossCheckRecord.fileName, "crosscheck.json")
    }
}
