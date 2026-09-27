import XCTest
import IntakeKit

final class PlanMetricsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)

    // MARK: - delta: line counts

    func testDeltaCountsAddedAndRemovedLines() {
        let old = "one\ntwo\nthree\nfour\n"
        let new = "one\ntwo (edited)\nthree\nfive\nfour\n"
        let d = PlanMetrics.delta(from: old, to: new)
        // "two" -> "two (edited)" is a remove+add pair; "five" is a pure add.
        XCTAssertEqual(d.removed, 1)
        XCTAssertEqual(d.added, 2)
    }

    func testDeltaOnIdenticalTextIsZero() {
        let text = "a\nb\nc\n"
        let d = PlanMetrics.delta(from: text, to: text)
        XCTAssertEqual(d.added, 0)
        XCTAssertEqual(d.removed, 0)
        XCTAssertEqual(d.sectionsChanged, [])
    }

    // MARK: - sectionsChanged

    func testSectionsChangedNamesHeadingsWithChangedBodies() {
        let old = """
        # Title
        preamble line
        ## Foo
        foo body
        ## Bar
        bar body
        """
        let new = """
        # Title
        preamble line
        ## Foo
        foo body changed
        ## Bar
        bar body
        """
        let d = PlanMetrics.delta(from: old, to: new)
        XCTAssertEqual(d.sectionsChanged, ["## Foo"])
    }

    func testPreambleChangeReportsPseudoHeading() {
        let old = """
        preamble line
        ## Foo
        foo body
        """
        let new = """
        preamble line changed
        ## Foo
        foo body
        """
        let d = PlanMetrics.delta(from: old, to: new)
        XCTAssertEqual(d.sectionsChanged, ["(preamble)"])
    }

    /// A heading renamed with its body untouched is a change to the *new* name only — the
    /// old name doesn't also show up as "removed", because its content (the body) survives.
    func testRenamedHeadingWithUnchangedBodyReportsOnlyNewName() {
        let old = """
        # Title
        ## Foo
        shared body line
        """
        let new = """
        # Title
        ## Bar
        shared body line
        """
        let d = PlanMetrics.delta(from: old, to: new)
        XCTAssertEqual(d.sectionsChanged, ["## Bar"])
    }

    /// A whole section (heading + body) removed with nothing renamed in its place: the heading
    /// genuinely has no counterpart left in the new document, so it's reported as old-only,
    /// after every heading that changed in the new document.
    func testWhollyRemovedSectionReportsOldOnlyAfterNewChanges() {
        let old = """
        # Title
        ## Keep
        keep body
        ## Gone
        gone body
        """
        let new = """
        # Title
        ## Keep
        keep body changed
        """
        let d = PlanMetrics.delta(from: old, to: new)
        XCTAssertEqual(d.sectionsChanged, ["## Keep", "## Gone"])
    }

    func testNewSectionAddedReportsInNewDocumentOrder() {
        let old = """
        # Title
        ## First
        first body
        """
        let new = """
        # Title
        ## First
        first body
        ## Second
        second body
        """
        let d = PlanMetrics.delta(from: old, to: new)
        XCTAssertEqual(d.sectionsChanged, ["## Second"])
    }

    // MARK: - unifiedDiff

    func testUnifiedDiffMatchesExpectedHunk() {
        let old = "a\nb\nc\nd\ne\nf\ng\n"
        let new = "a\nb\nc\nX\ne\nf\ng\n"
        let diff = PlanMetrics.unifiedDiff(from: old, to: new)
        let expected = """
        @@ -1,7 +1,7 @@
         a
         b
         c
        -d
        +X
         e
         f
         g
        """
        XCTAssertEqual(diff, expected)
    }

    func testUnifiedDiffOnIdenticalTextIsEmpty() {
        let text = "a\nb\nc\n"
        XCTAssertEqual(PlanMetrics.unifiedDiff(from: text, to: text), "")
    }

    func testUnifiedDiffSplitsDistantHunks() {
        // Two changes far enough apart (more than 2*context lines of shared context between
        // them) must produce two separate @@ hunks, not one giant one.
        let oldLines = (1...20).map { "line\($0)" }
        var newLines = oldLines
        newLines[1] = "line2-edited"
        newLines[18] = "line19-edited"
        let old = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        let diff = PlanMetrics.unifiedDiff(from: old, to: new)
        XCTAssertEqual(diff.components(separatedBy: "@@ -").count - 1, 2, diff)
    }

    // MARK: - opsChanged

    func testOpsChangedCountsAddedRemovedAndModified() {
        let old = ChangeSet(graphObservedAt: t0, ops: [
            .createBead(NewBead(tempId: "n1", title: "kept", description: "d")),
            .editBead(id: "br-1", set: FieldSet(title: "old title"),
                      pre: Precondition(status: "open", assignee: nil), delivery: nil),
            .reopen(id: "br-2", reason: "removed op", pre: Precondition(status: "closed", assignee: nil)),
        ])
        let new = ChangeSet(graphObservedAt: t0, ops: [
            .createBead(NewBead(tempId: "n1", title: "kept", description: "d")),
            .editBead(id: "br-1", set: FieldSet(title: "new title"),
                      pre: Precondition(status: "open", assignee: nil), delivery: nil),
            .createBead(NewBead(tempId: "n2", title: "new bead", description: "d2")),
        ])
        // br-1's edit is modified (1), br-2's reopen is removed (1), n2's create is added (1).
        XCTAssertEqual(PlanMetrics.opsChanged(from: old, to: new), 3)
    }

    func testOpsChangedIsZeroForIdenticalChangeSets() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [
            .createBead(NewBead(tempId: "n1", title: "t", description: "d")),
        ])
        XCTAssertEqual(PlanMetrics.opsChanged(from: cs, to: cs), 0)
    }

    func testOpsChangedMatchesEdgesByEndpointsNotKind() {
        let old = ChangeSet(graphObservedAt: t0, ops: [
            .addEdge(from: .existing("br-1"), to: .existing("br-2"), kind: .related),
        ])
        let new = ChangeSet(graphObservedAt: t0, ops: [
            .addEdge(from: .existing("br-1"), to: .existing("br-2"), kind: .blocks),
        ])
        // Same edge, kind flipped: one modification, not a remove+add pair.
        XCTAssertEqual(PlanMetrics.opsChanged(from: old, to: new), 1)
    }

    // MARK: - performance

    func testDeltaOnLargePlanFinishesUnderTwoSeconds() {
        var oldLines: [String] = []
        for i in 0..<6000 { oldLines.append("plan line \(i) of the round") }
        var newLines = oldLines
        for i in 2900..<3100 { newLines[i] = "plan line \(i) of the round, revised" }
        let old = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"

        let clock = ContinuousClock()
        let start = clock.now
        let d = PlanMetrics.delta(from: old, to: new)
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(d.added, 200)
        XCTAssertEqual(d.removed, 200)
        XCTAssertLessThan(elapsed, .seconds(2), "diffing 6,000 lines took \(elapsed)")
    }
}
