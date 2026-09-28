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

    /// A CRLF plan must diff identically to its LF twin: splitting on "\n" as a `Character`
    /// never fires inside a CRLF pair ("\r\n" is one grapheme cluster), so before the fix a
    /// whole CRLF plan diffed as a single line and reported no section changes at all.
    func testCRLFPlanMatchesLFPlan() {
        let oldLF = "# Title\n## Foo\nfoo body\n## Bar\nbar body\n"
        let newLF = "# Title\n## Foo\nfoo body changed\n## Bar\nbar body\n"
        let oldCRLF = oldLF.replacingOccurrences(of: "\n", with: "\r\n")
        let newCRLF = newLF.replacingOccurrences(of: "\n", with: "\r\n")

        let lfDelta = PlanMetrics.delta(from: oldLF, to: newLF)
        let crlfDelta = PlanMetrics.delta(from: oldCRLF, to: newCRLF)

        XCTAssertEqual(crlfDelta.added, lfDelta.added)
        XCTAssertEqual(crlfDelta.removed, lfDelta.removed)
        XCTAssertEqual(crlfDelta.sectionsChanged, lfDelta.sectionsChanged)
        XCTAssertEqual(crlfDelta.sectionsChanged, ["## Foo"])
    }

    /// A section that's both renamed AND moved earlier proves `sectionsChanged` sorts by real
    /// document position rather than by when a change happens to surface while walking the edit
    /// script: the edit script reaches "## Foo"'s delete (mapped to "## FooRenamed", which now
    /// sits at new-document position 3) before it reaches "## Qux"'s insert (new-document
    /// position 1), so an implementation that just appended in edit-script order would report
    /// ["## FooRenamed", "## Qux", "## Bar"] -- backwards.
    func testSectionsChangedOrderSurvivesAMovedSection() {
        let old = """
        # Title
        ## Foo
        shared body FOO
        ## Bar
        totally different bar body old
        """
        let new = """
        # Title
        ## Qux
        qux body
        ## FooRenamed
        shared body FOO
        """
        let d = PlanMetrics.delta(from: old, to: new)
        XCTAssertEqual(d.sectionsChanged, ["## Qux", "## FooRenamed", "## Bar"])
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

    /// Two `followUp`s targeting the same bead collide on the same `BaseOpKey`; without an
    /// occurrence index, both old-side entries collapse into one dictionary slot and only the
    /// last write survives, so a real change on the first one reads back as unmodified (0)
    /// instead of the expected 1. Pairing occurrence-by-occurrence (old[0]<->new[0],
    /// old[1]<->new[1]) keeps them distinguishable.
    func testOpsChangedCountsAChangeInADuplicateFollowUpByOccurrence() {
        let old = ChangeSet(graphObservedAt: t0, ops: [
            .followUp(tempId: "n1", of: "br-1", title: "first follow-up", description: "d1",
                      pre: Precondition(status: "open", assignee: nil)),
            .followUp(tempId: "n2", of: "br-1", title: "second follow-up", description: "d2",
                      pre: Precondition(status: "open", assignee: nil)),
        ])
        let new = ChangeSet(graphObservedAt: t0, ops: [
            .followUp(tempId: "n1", of: "br-1", title: "first follow-up, revised", description: "d1",
                      pre: Precondition(status: "open", assignee: nil)),
            .followUp(tempId: "n2", of: "br-1", title: "second follow-up", description: "d2",
                      pre: Precondition(status: "open", assignee: nil)),
        ])
        XCTAssertEqual(PlanMetrics.opsChanged(from: old, to: new), 1)
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

    /// Polish's top-weighted convergence signal is "dependencies stabilizing", which
    /// `opsChanged` folds in with every bead edit. `edgesChanged` is the edge share alone, by
    /// the same matching rules: added, removed, and a kind flip as one modification.
    func testEdgesChangedCountsOnlyDependencyEdges() {
        let old = ChangeSet(graphObservedAt: t0, ops: [
            .createBead(NewBead(tempId: "n1", title: "t", description: "d")),
            .addEdge(from: .existing("br-1"), to: .existing("br-2"), kind: .related),
            .addEdge(from: .existing("br-1"), to: .existing("br-3"), kind: .blocks),
        ])
        let new = ChangeSet(graphObservedAt: t0, ops: [
            .createBead(NewBead(tempId: "n1", title: "t, revised", description: "d")),
            .addEdge(from: .existing("br-1"), to: .existing("br-2"), kind: .blocks),
            .addEdge(from: .new("n1"), to: .existing("br-1"), kind: .blocks),
        ])
        // Edges: br-1→br-2 kind flip (1), br-1→br-3 removed (1), n1→br-1 added (1). The bead
        // edit is not an edge.
        XCTAssertEqual(PlanMetrics.edgesChanged(from: old, to: new), 3)
        XCTAssertEqual(PlanMetrics.opsChanged(from: old, to: new), 4)
        XCTAssertEqual(PlanMetrics.edgesChanged(from: new, to: new), 0)
    }

    // MARK: - sectionChurn

    /// How much each section moved, not just which: lines added plus removed, attributed to
    /// the heading they sit under.
    func testSectionChurnCountsChangedLinesPerHeading() {
        let old = """
        # Plan
        ## 1. Scope
        a
        b
        ## 4. Rollout
        x
        y
        z
        """
        let new = """
        # Plan
        ## 1. Scope
        a
        b2
        ## 4. Rollout
        x2
        y2
        z
        w
        """
        XCTAssertEqual(PlanMetrics.sectionChurn(from: old, to: new), ["## 1. Scope": 2, "## 4. Rollout": 5])
        XCTAssertEqual(PlanMetrics.sectionChurn(from: old, to: old), [:])
    }

    /// Same rename rule `sectionsChanged` follows: a renamed heading's churn lands on the new
    /// name, and a section removed outright keeps its old one.
    func testSectionChurnFollowsARenameAndKeepsARemovedSection() {
        let old = """
        ## Foo
        foo body
        ## Gone
        g1
        g2
        """
        let new = """
        ## Bar
        foo body
        """
        XCTAssertEqual(PlanMetrics.sectionChurn(from: old, to: new), ["## Bar": 2, "## Gone": 3])
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
