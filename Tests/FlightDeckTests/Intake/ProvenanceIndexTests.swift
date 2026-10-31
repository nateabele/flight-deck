import XCTest
import IntakeKit

/// `ProvenanceIndex` over a scrubbed copy of a real intake's first three checkpoints
/// (`Fixtures/Threads/provenance-intake`): two drafts with different outlines, a synthesis
/// round that consumed eight notes, and a cross-check Refine round with 77 changes, three
/// clusters and a verdict on each. The prose is filler; the shapes are the real run's.
final class ProvenanceIndexTests: XCTestCase {
    private var intake: URL!
    private var tape: Tape!
    private var store: TapeStore!

    override func setUpWithError() throws {
        intake = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "provenance-intake", withExtension: nil,
                                                          subdirectory: "Fixtures/Threads"))
        store = TapeStore(intakeDirectory: intake)
        tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.map(\.id), [1, 2, 3], "the fixture's tape decodes")
    }

    private func index(_ cp: Int, section: String?) -> ProvenanceIndex {
        let checkpoint = tape.checkpoints.first { $0.id == cp }!
        return ProvenanceIndex.build(checkpoint: checkpoint, label: ThreadWorkspace.label(checkpoint),
                                     directory: store.checkpointDirectory(cp), section: section)
    }

    /// Each draft gives its own version of the section, found by heading even at another level
    /// (draft 1 has it as a `###` under its own outline); a section a draft lacks gives nothing
    /// from it rather than a guess.
    func testDraftsGiveTheirVersionOfTheSection() {
        let drafts = index(1, section: "Phase 3: workstream 3").items
        XCTAssertEqual(drafts.map(\.id), ["cp1.d0", "cp1.d1"])
        XCTAssertEqual(drafts.first?.kind, .draft)
        XCTAssertTrue(drafts[0].text.contains("## Phase 3: workstream 3"))
        XCTAssertTrue(drafts[1].text.contains("### Phase 3: workstream 3"))
        XCTAssertFalse(drafts[0].text.contains("## Phase 4"), "the section only, not the rest of the draft")
        XCTAssertEqual(index(1, section: "Product decisions").items.map(\.id), ["cp1.d0"],
                       "draft 1's outline has no such section")
    }

    /// A Refine round's proposals labelled `Phase 3 — item n` (and the full title) are the ones
    /// that touch the section, each with the integrator's verdict and its proposer's family;
    /// `Phase 3` never matches `Phase 30` or another phase.
    func testVerdictsAreTheChangesThatTouchTheSection() {
        let refine = index(3, section: "Phase 3: workstream 3")
        let verdicts = refine.items.filter { $0.kind == .verdict }
        XCTAssertEqual(verdicts.map(\.id), [6, 11, 15, 23, 25, 48, 76].map { "cp3.v\($0)" })
        XCTAssertTrue(verdicts.first { $0.id == "cp3.v15" }?.text.hasPrefix("somewhat, proposed by codex") ?? false)
        XCTAssertTrue(verdicts.first { $0.id == "cp3.v23" }?.text.hasPrefix("somewhat, proposed by gemini") ?? false)
    }

    /// A cluster is listed when any member touches the section, with every member cited, so
    /// the agent can see the same issue was raised elsewhere too.
    func testClustersThatTouchTheSectionAreListedWithEveryMember() {
        let clusters = index(3, section: "Phase 3: workstream 3").items.filter { $0.kind == .cluster }
        XCTAssertEqual(clusters.map(\.id), ["cp3.x0"])
        for member in [16, 18, 25, 26, 60] {
            XCTAssertTrue(clusters[0].text.contains("[cite:cp3.v\(member)]"), "member \(member)")
        }
    }

    /// The notes a round consumed that were anchored in the section.
    func testConsumedNotesInTheSection() {
        let notes = index(2, section: "Phase 3: workstream 3").items.filter { $0.kind == .note }
        XCTAssertEqual(notes.map(\.id), ["cp2.n6"])
        XCTAssertTrue(notes[0].text.hasPrefix("comment on “"))
    }

    /// A whole-plan thread gets everything: every change, every cluster, every note.
    func testAWholePlanThreadGetsEveryItem() {
        let refine = index(3, section: nil)
        XCTAssertEqual(refine.items.filter { $0.kind == .verdict }.count, 77)
        XCTAssertEqual(refine.items.filter { $0.kind == .cluster }.count, 3)
        XCTAssertEqual(index(2, section: nil).items.filter { $0.kind == .note }.count, 8)
        XCTAssertEqual(index(1, section: nil).items.map(\.id), ["cp1.d0", "cp1.d1"], "each draft by its outline")
    }

    /// Building twice gives the same ids for the same items: a citation in an earlier turn's
    /// reply still names what it named.
    func testIDsAreStableAcrossBuilds() {
        XCTAssertEqual(index(3, section: "Phase 3: workstream 3"), index(3, section: "Phase 3: workstream 3"))
    }

    /// The markdown cites each item, and an index with nothing says so.
    func testMarkdownCitesEveryItem() {
        let refine = index(3, section: "Phase 3: workstream 3")
        for id in refine.ids { XCTAssertTrue(refine.markdown.contains("[cite:\(id)]"), id) }
        XCTAssertTrue(index(2, section: "Phase 5: workstream 5").markdown.contains("Nothing here touches it."))
    }

    func testCitationsAreReadOutOfAReply() {
        XCTAssertEqual(ProvenanceIndex.citations(in: "As [cite:cp3.v6] and [cite:cp2.n6] say, but [cite:] and [cite:a b]."),
                       ["cp3.v6", "cp2.n6"])
    }

    /// Round labels match by their part before the em dash, on a word boundary.
    func testSectionLabelsMatchLoosely() {
        XCTAssertTrue(PlanOutline.touches(label: "Phase 3 — item 2", title: "Phase 3: durable state"))
        XCTAssertTrue(PlanOutline.touches(label: "Release verification — item 4", title: "Release verification and done"))
        XCTAssertTrue(PlanOutline.touches(label: "Phase 3: durable state", title: "Phase 3: durable state"))
        XCTAssertFalse(PlanOutline.touches(label: "Phase 1 — item 2", title: "Phase 10: later"))
        XCTAssertFalse(PlanOutline.touches(label: "Phase 3 — item 2", title: "Phase 4: other"))
    }
}
