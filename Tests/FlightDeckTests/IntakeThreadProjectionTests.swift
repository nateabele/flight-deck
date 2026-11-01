import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// A reader that serves canned threads, standing in for Stream A's on-disk store.
struct FakeThreadReader: ThreadStoreReading {
    var records: [ThreadRecord] = []
    var turnsByThread: [ThreadID: [ThreadTurn]] = [:]
    var diffsByThread: [ThreadID: [ThreadDiff]] = [:]
    func threads() -> [ThreadRecord] { records }
    func turns(_ id: ThreadID) -> [ThreadTurn] { turnsByThread[id] ?? [] }
    func diffs(_ id: ThreadID) -> [ThreadDiff] { diffsByThread[id] ?? [] }
    func activity(_ id: ThreadID) -> String? { nil }
}

/// What the phone is told about threads: summaries with counts and an excerpt, pending diffs
/// placed by block, the needs-you count, and the on-demand page.
final class IntakeThreadProjectionTests: XCTestCase {
    private let markdown = "# Plan\n\nThe first paragraph.\n\nWe ship on Friday.\n\nLast words."
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: ThreadID, status: ThreadStatus, quote: String? = nil) -> ThreadRecord {
        ThreadRecord(id: id, title: "Why Friday?",
                     anchor: quote.map { ThreadAnchor(note: NoteAnchor(checkpoint: 3, quote: $0, section: "Plan")) } ?? .wholePlan,
                     status: status, agent: .codex, model: "m", effort: "high", followsCheckpoint: 3, createdAt: date)
    }

    private func turn(_ seq: Int, reply: String? = nil, actions: [ThreadAction] = []) -> ThreadTurn {
        ThreadTurn(seq: seq, messageID: "m\(seq)", you: seq == 1 ? "why?" : nil, reply: reply, actions: actions,
                   checkpoint: 3, startedAt: date, endedAt: date)
    }

    private func question() -> StructuredQuestion {
        StructuredQuestion(id: "q1", text: "Which day?", kind: .single,
                           options: [StructuredQuestion.Option(id: "fri", label: "Friday"), StructuredQuestion.Option(id: "mon", label: "Monday")])
    }

    private func fixture() -> (FakeThreadReader, ThreadID, ThreadID) {
        let a = ThreadID(), b = ThreadID()
        let diff = ThreadDiff(thread: a, turn: 2, checkpoint: 3, anchor: NoteAnchor(checkpoint: 3, quote: "We ship on Friday."),
                              old: "We ship on Friday.", new: "We ship on Monday.")
        var decided = diff; decided.id = UUID(); decided.state = .accepted
        var stale = diff; stale.id = UUID(); stale.state = .stale
        let reader = FakeThreadReader(
            records: [record(a, status: .needsYou, quote: "We ship on Friday."), record(b, status: .resolved)],
            turnsByThread: [a: [turn(1), turn(2, reply: "Monday is safer.\nBecause of the freeze.", actions: [.askQuestion(question())])],
                            b: [turn(1, reply: "Done.")]],
            diffsByThread: [a: [diff, decided, stale]])
        return (reader, a, b)
    }

    func testSummaryCarriesCountsExcerptAndAnchorBlock() {
        let (reader, a, _) = fixture()
        let blocks = PlanBlocks.split(markdown)
        let s = IntakeThreadProjection.threads(reader: reader, blocks: blocks).first { $0.id == a.raw }
        XCTAssertEqual(s?.status, "needsYou")
        XCTAssertEqual(s?.counts, WireThreadCounts(turns: 2, pendingDiffs: 2, openQuestions: 1))
        XCTAssertEqual(s?.excerpt, "Monday is safer.")
        XCTAssertEqual(s?.anchor?.quote, "We ship on Friday.")
        XCTAssertEqual(s?.anchor?.block, blocks.blocks.first { $0.text.contains("Friday") }?.index)
    }

    /// The phone's thread screen says "reads files only" as the Mac's header does: true for an
    /// agent with no shell (grok, opencode), absent for one that runs read commands.
    func testTheSummarySaysWhenTheAgentReadsFilesOnly() {
        for agent in AgentID.allCases {
            var r = record(ThreadID(), status: .open)
            r.agent = agent
            let s = IntakeThreadProjection.summary(r, reader: FakeThreadReader(records: [r]), blocks: PlanBlocks.split(markdown))
            XCTAssertEqual(s.readsFilesOnly, HeadlessCommand.threadReadsFilesOnly(agent) ? true : nil, "\(agent)")
        }
        XCTAssertTrue([AgentID.grok, .opencode].allSatisfy(HeadlessCommand.threadReadsFilesOnly))
    }

    func testWholePlanThreadHasNoAnchor() {
        let (reader, _, b) = fixture()
        let s = IntakeThreadProjection.threads(reader: reader, blocks: PlanBlocks.split(markdown)).first { $0.id == b.raw }
        XCTAssertNil(s?.anchor)
    }

    func testPendingDiffsListPendingAndStaleButNotDecided() {
        let (reader, a, _) = fixture()
        let blocks = PlanBlocks.split(markdown)
        let diffs = IntakeThreadProjection.pendingDiffs(reader: reader, blocks: blocks)
        XCTAssertEqual(Set(diffs.map(\.state)), ["pending", "stale"])
        XCTAssertTrue(diffs.allSatisfy { $0.thread == a.raw && $0.old == "We ship on Friday." })
        XCTAssertTrue(diffs.allSatisfy { $0.blockIndex == blocks.blocks.first { $0.text.contains("Friday") }?.index })
    }

    func testNeedingYouCountsOnlyNeedsYouThreads() {
        let (reader, _, _) = fixture()
        XCTAssertEqual(IntakeThreadProjection.needingYou(reader: reader), 1)
        XCTAssertEqual(IntakeThreadProjection.needingYou(reader: FakeThreadReader()), 0)
    }

    func testPageHonoursSinceAndLinksDiffsAndQuestionsToTheirTurn() {
        let (reader, a, _) = fixture()
        let blocks = PlanBlocks.split(markdown)
        let full = IntakeThreadProjection.page(reader: reader, thread: a, since: nil, blocks: blocks)
        XCTAssertEqual(full?.turns.map(\.seq), [1, 2])
        XCTAssertEqual(full?.turns[1].questions?.first?.id, "q1")
        XCTAssertEqual(full?.turns[1].diffs?.count, 3)
        let later = IntakeThreadProjection.page(reader: reader, thread: a, since: 1, blocks: blocks)
        XCTAssertEqual(later?.turns.map(\.seq), [2])
        XCTAssertNil(IntakeThreadProjection.page(reader: reader, thread: ThreadID(), since: nil, blocks: blocks))
    }

    func testAnswersRideTheirTurn() {
        let a = ThreadID()
        var t = turn(3)
        t.answers = [StructuredAnswer(questionID: "q1", selected: ["fri"])]
        let reader = FakeThreadReader(records: [record(a, status: .answering)], turnsByThread: [a: [t]])
        let page = IntakeThreadProjection.page(reader: reader, thread: a, since: nil, blocks: PlanBlocks.split(markdown))
        XCTAssertEqual(page?.turns.first?.answers, [WireStructuredAnswer(questionID: "q1", selected: ["fri"])])
    }
}
