import XCTest
import FleetKit

/// Ask threads on the fleet wire (P1 Task 0): the ops, the reply and the projection fields, as
/// bytes. Pure FleetKit, nothing from the app, so the local logic lane can take this file whole.
/// What the Mac does with the ops is `IntakeThreadServiceTests`.
final class ThreadWireCodingTests: XCTestCase {
    private let intake = UUID()
    private let thread = UUID()

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    /// Every thread command with its dotted op, for the coding and scope tests.
    static func commands(intake: UUID, thread: UUID) -> [(FleetCommand, String)] {
        let token = UUID()
        return [
            (.intakeThreadSend(id: intake, token: token, threadID: nil,
                               anchor: WireThreadAnchor(checkpoint: 3, block: 7, quote: "the job"), text: "Why?"),
             "intake.thread.send"),
            (.intakeThreadSend(id: intake, token: token, threadID: thread, anchor: nil, text: "And then?"),
             "intake.thread.send"),
            (.intakeThreadAnswer(id: intake, token: token, threadID: thread,
                                 answers: [WireStructuredAnswer(questionID: "q1", selected: ["a"], other: "and b")]),
             "intake.thread.answer"),
            (.intakeThreadResolve(id: intake, token: token, threadID: thread), "intake.thread.resolve"),
            (.intakeDiffDecide(id: intake, token: token, threadID: thread, diffID: UUID(), accept: true), "intake.diff.decide"),
        ]
    }

    // MARK: - Ops

    func testEveryThreadCommandRoundTripsUnderItsDottedOp() throws {
        for (command, op) in Self.commands(intake: intake, thread: thread) {
            let data = try JSONEncoder().encode(command)
            XCTAssertEqual(try JSONDecoder().decode(FleetCommand.self, from: data), command)
            let obj = try object(command)
            XCTAssertEqual(obj["op"] as? String, op)
            XCTAssertEqual(obj["id"] as? String, intake.uuidString, "the intake rides `id`, like the sibling intake ops")
            XCTAssertNotNil(obj["token"])
        }
    }

    /// Opening a thread sends no `threadID` and, about the whole plan, no anchor: both absent,
    /// never null.
    func testANewWholePlanThreadOmitsThreadAndAnchor() throws {
        let obj = try object(FleetCommand.intakeThreadSend(id: intake, token: UUID(), threadID: nil, anchor: nil, text: "t"))
        XCTAssertEqual(Set(obj.keys), ["op", "id", "token", "text"])
    }

    func testThreadAnswerCarriesItsAnswersUnderTheSiblingKey() throws {
        let obj = try object(FleetCommand.intakeThreadAnswer(id: intake, token: UUID(), threadID: thread, answers: []))
        XCTAssertEqual(Set(obj.keys), ["op", "id", "token", "threadID", "answers"])
    }

    /// A read, so a request (`req`, answered on its `cid`) like `intake.plan`, not a command.
    func testThreadGetIsARequestAnsweredWithAPage() throws {
        for request in [FleetRequest.intakeThreadGet(id: intake, threadID: thread, since: 4),
                        .intakeThreadGet(id: intake, threadID: thread, since: nil)] {
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), request)
            XCTAssertEqual(try object(request)["op"] as? String, "intake.thread.get")
        }
        let frame = ServerFrame.intakeThread(cid: 9, Self.page)
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
        XCTAssertEqual(frame.correlationID, 9)
    }

    // MARK: - Projection

    static let summary = WireThreadSummary(
        id: UUID(), title: "Why Unassigned?",
        anchor: WireThreadAnchor(checkpoint: 3, block: 7, quote: "the job", section: "## Scope"),
        status: "needsYou", counts: WireThreadCounts(turns: 2, pendingDiffs: 1, openQuestions: 1),
        excerpt: "Because the dispatcher…")

    static let pendingDiff = WirePendingDiff(id: UUID(), thread: UUID(), checkpoint: 3, blockIndex: 7,
                                             old: "the job stays Unassigned", new: "the job stays with its dispatcher",
                                             state: "pending")

    static let page = WireThreadPage(
        thread: summary,
        turns: [WireThreadTurn(seq: 1, messageID: "m1", you: "Why?", answers: nil, reply: "See [cite:d1].",
                               decision: "Keep it.", questions: [WireStructuredQuestion(id: "q1", text: "Q?", kind: "text")],
                               diffs: [pendingDiff.id], errors: [], checkpoint: 3,
                               startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                               endedAt: Date(timeIntervalSince1970: 1_800_000_010))],
        diffs: [pendingDiff])

    func testProjectionShapesRoundTrip() throws {
        XCTAssertEqual(try JSONDecoder().decode(WireThreadPage.self, from: JSONEncoder().encode(Self.page)), Self.page)
        XCTAssertEqual(try JSONDecoder().decode(WireThreadSummary.self, from: JSONEncoder().encode(Self.summary)), Self.summary)
        XCTAssertEqual(try JSONDecoder().decode(WirePendingDiff.self, from: JSONEncoder().encode(Self.pendingDiff)), Self.pendingDiff)
    }

    /// The phone places a diff by its block, as it places a note; `old` is the passage replaced.
    /// No separate quote: it would only repeat `old`.
    func testAPendingDiffIsPlacedByBlockAndCarriesNoQuote() throws {
        let obj = try object(Self.pendingDiff)
        XCTAssertEqual(Set(obj.keys), ["id", "thread", "checkpoint", "blockIndex", "old", "new", "state"])
        var unplaced = Self.pendingDiff
        unplaced.blockIndex = nil
        XCTAssertNil(try object(unplaced)["blockIndex"])
        XCTAssertEqual(try JSONDecoder().decode(WirePendingDiff.self, from: JSONEncoder().encode(unplaced)), unplaced)
    }

    /// "reads files only" rides on the summary for the phone's header: true for an agent with no
    /// shell, absent otherwise, so an old phone's bytes are unchanged and an old Mac's decode nil.
    func testReadsFilesOnlyIsAbsentUnlessTrue() throws {
        XCTAssertNil(try object(Self.summary)["readsFilesOnly"])
        var grok = Self.summary
        grok.readsFilesOnly = true
        XCTAssertEqual(try object(grok)["readsFilesOnly"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(WireThreadSummary.self, from: JSONEncoder().encode(grok)), grok)
        XCTAssertNil(try JSONDecoder().decode(WireThreadSummary.self, from: JSONEncoder().encode(Self.summary)).readsFilesOnly)
    }

    /// A status a later Mac invents still decodes: it is a string on the wire for that reason.
    func testAnUnknownStatusStringStillDecodes() throws {
        var summary = Self.summary
        summary.status = "someFutureStatus"
        XCTAssertEqual(try JSONDecoder().decode(WireThreadSummary.self, from: JSONEncoder().encode(summary)).status,
                       "someFutureStatus")
    }

    /// An old Mac's detail has no `threads` flag: the phone reads nil and offers no Ask.
    func testAnOldMacsDetailAndPlanHaveNoThreads() throws {
        let detail = WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "T", state: "shaping", needsAttention: false,
                                       createdAt: Date(timeIntervalSince1970: 1)),
            intent: "i", servedAt: Date(timeIntervalSince1970: 2), structuredQuestions: true)
        let obj = try object(detail)
        XCTAssertNil(obj["threads"], "nil is absent, so the bytes an old phone reads are unchanged")
        let decoded = try JSONDecoder().decode(WireIntakeDetail.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(decoded.threads)

        let plan = WireIntakePlan(checkpoint: 1, roundName: "Draft", editsVersion: "", markdown: "# P")
        let planObj = try object(plan)
        XCTAssertNil(planObj["threads"])
        XCTAssertNil(planObj["pendingDiffs"])
        let old = ##"{"checkpoint":1,"roundName":"Draft","editsVersion":"","markdown":"# P","outline":[],"notes":[]}"##
        let oldPlan = try JSONDecoder().decode(WireIntakePlan.self, from: Data(old.utf8))
        XCTAssertNil(oldPlan.threads)
        XCTAssertNil(oldPlan.pendingDiffs)

        var withThreads = plan
        withThreads.threads = [Self.summary]
        withThreads.pendingDiffs = [Self.pendingDiff]
        XCTAssertEqual(try JSONDecoder().decode(WireIntakePlan.self, from: JSONEncoder().encode(withThreads)), withThreads)
    }

    /// The fleet list's "needs you" count rides the summary; absent from an old Mac, and from
    /// this one while it is nil.
    func testTheSummarysNeedsYouCountIsOptional() throws {
        let summary = WireIntakeSummary(id: UUID(), title: "T", state: "shaping", needsAttention: false,
                                        createdAt: Date(timeIntervalSince1970: 1))
        XCTAssertNil(try object(summary)["threadsNeedingYou"])
        var counted = summary
        counted.threadsNeedingYou = 2
        XCTAssertEqual(try JSONDecoder().decode(WireIntakeSummary.self, from: JSONEncoder().encode(counted)), counted)
        let old = #"{"id":"\#(UUID().uuidString)","title":"T","state":"shaping","needsAttention":false,"createdAt":1}"#
        XCTAssertNil(try JSONDecoder().decode(WireIntakeSummary.self, from: Data(old.utf8)).threadsNeedingYou)
    }

    /// C-7: a turn from a Mac that leaves `errors` or `checkpoint` out still decodes, with no
    /// errors and checkpoint 0, like every other optional field in this file.
    func testATurnWithoutErrorsOrCheckpointStillDecodes() throws {
        let json = #"{"seq":3,"messageID":"m","startedAt":1}"#
        let turn = try JSONDecoder().decode(WireThreadTurn.self, from: Data(json.utf8))
        XCTAssertEqual(turn.errors, [])
        XCTAssertEqual(turn.checkpoint, 0)
        XCTAssertEqual(turn.seq, 3)
    }

    /// C-I1: the answer op carries its turn when given, and omits it otherwise (an older phone).
    func testThreadAnswerCarriesItsTurnOnlyWhenGiven() throws {
        let with = FleetCommand.intakeThreadAnswer(id: UUID(), token: UUID(), threadID: UUID(), answers: [], turn: 4)
        XCTAssertEqual(try object(with)["turn"] as? Int, 4)
        XCTAssertEqual(try JSONDecoder().decode(FleetCommand.self, from: JSONEncoder().encode(with)), with)
        XCTAssertNil(try object(FleetCommand.intakeThreadAnswer(id: UUID(), token: UUID(), threadID: UUID(), answers: []))["turn"])
    }
}
