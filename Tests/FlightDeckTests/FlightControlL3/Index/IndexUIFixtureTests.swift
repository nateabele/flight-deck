import XCTest
import IntakeKit
@testable import FlightDeck

/// The UI test steals the screen for a minute, so its fixture is proven sound here first:
/// both snapshots decode, the newer is current, their stored scores are exactly what the
/// scorer computes from their rows (so the heatmap shows real arithmetic), the diff is the two
/// rows the UI test expects, and the cell it clicks has a citation.
final class IndexUIFixtureTests: XCTestCase {
    func testUIFixtureSnapshotsAreSoundAndDiffAsTheUITestExpects() throws {
        let copy = IndexFixtures.scratch()
        try FileManager.default.copyItem(at: try IndexFixtures.uiDirectory(), to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        let store = IndexSnapshotStore(directory: copy)

        let current = try XCTUnwrap(store.current())
        XCTAssertEqual(current.ref.stamp, "2026-10-04T060000Z")
        let previous = try XCTUnwrap(store.previous(before: current.ref))
        XCTAssertEqual(previous.ref.stamp, "2026-09-27T060000Z")

        for snap in [current.snapshot, previous.snapshot] {
            let recomputed = IndexSnapshot.assemble(results: snap.sources, sources: IndexSourceRegistry.initial,
                                                    aliases: AliasTable(entries: snap.aliases), createdAt: snap.createdAt)
            XCTAssertEqual(recomputed.scores, snap.scores, "stored scores must be what the scorer computes")
            XCTAssertEqual(recomputed.unmapped, snap.unmapped)
        }

        let changes = SnapshotDiff.changes(from: previous.snapshot, to: current.snapshot)
        XCTAssertEqual(changes.map(CapabilityIndexPane.describe), [
            "claude · opus (effort high) — test-authoring 0.80 → 0.60 (-0.20)",
            "codex · gpt-6-sol (effort high) — test-authoring 0.60 → 0.80 (+0.20)"])

        let cited = CapabilityScoring.citations(for: IndexFixtures.sol, dimension: "test-authoring",
                                                snapshot: current.snapshot, sources: IndexSourceRegistry.initial)
        XCTAssertEqual(cited.map(\.url), ["https://swtbench.com/"])
        XCTAssertEqual(current.snapshot.sources.first { $0.sourceID == "terminal-bench" }?.stale, true)
    }
}
