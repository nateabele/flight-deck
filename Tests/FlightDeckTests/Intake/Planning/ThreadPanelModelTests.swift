import Combine
import IntakeKit
import XCTest
@testable import FlightDeck

/// A reader a test can change under the model, the way ThreadRunner changes the real one.
final class FakeThreadStore: ThreadStoreReading {
    var records: [ThreadRecord] = []
    var turnsByThread: [ThreadID: [ThreadTurn]] = [:]
    var diffsByThread: [ThreadID: [ThreadDiff]] = [:]
    var live: [ThreadID: String] = [:]
    private(set) var reads = 0
    private(set) var turnReads = 0

    func threads() -> [ThreadRecord] { reads += 1; return records }
    func turns(_ id: ThreadID) -> [ThreadTurn] { turnReads += 1; return turnsByThread[id] ?? [] }
    func diffs(_ id: ThreadID) -> [ThreadDiff] { diffsByThread[id] ?? [] }
    func activity(_ id: ThreadID) -> String? { live[id] }

    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    @discardableResult
    func add(_ title: String, section: String? = nil, quote: String = "a quote", status: ThreadStatus = .open,
             autoAccept: Bool = false, follows: Int = 2) -> ThreadRecord {
        let anchor = ThreadAnchor(note: NoteAnchor(checkpoint: follows, quote: quote, section: section))
        let record = ThreadRecord(id: ThreadID(), title: title, anchor: anchor, status: status, agent: .claude,
                                  model: "opus", effort: "high", autoAccept: autoAccept, followsCheckpoint: follows,
                                  createdAt: Self.date.addingTimeInterval(Double(records.count)))
        records.append(record)
        return record
    }

    func addTurn(_ id: ThreadID, you: String? = nil, reply: String? = nil, actions: [ThreadAction] = [],
                 answers: [StructuredAnswer]? = nil) {
        let seq = (turnsByThread[id]?.count ?? 0) + 1
        turnsByThread[id, default: []].append(
            ThreadTurn(seq: seq, messageID: "m\(seq)", you: you, answers: answers, reply: reply, actions: actions,
                       checkpoint: 2, startedAt: Self.date))
    }

    func addDiff(_ id: ThreadID, state: DiffState = .pending) {
        diffsByThread[id, default: []].append(
            ThreadDiff(thread: id, checkpoint: 2, anchor: NoteAnchor(checkpoint: 2, quote: "old"), old: "old", new: "new",
                       state: state))
    }
}

@MainActor
final class ThreadPanelModelTests: XCTestCase {
    private var store: FakeThreadStore!
    private var intake: UUID!

    override func setUp() async throws {
        store = FakeThreadStore()
        intake = UUID()
        ThreadPanelModel.forgetSession()
    }

    private func model(_ actions: ThreadPanelModel.Actions = .init(), headings: [String] = [],
                       intake: UUID? = nil) -> ThreadPanelModel {
        ThreadPanelModel(intakeID: intake ?? self.intake, reader: store, actions: actions, headings: { headings })
    }

    private func question() -> ThreadAction {
        .askQuestion(StructuredQuestion(id: "q1", text: "Which?", kind: .single,
                                        options: [.init(id: "a", label: "A")]))
    }

    // MARK: Final review B

    /// B-I1: the plan draws proposals whether or not the rail or panel is on screen. The model polls
    /// on its own while the plan has a pending diff (a new one shows, a decided one goes), and lets
    /// go of the clock once there is none.
    func testTheModelPollsOnItsOwnWhileThePlanHasPendingDiffs() {
        let t = store.add("Why?")
        store.diffsByThread[t.id] = [ThreadDiff(thread: t.id, turn: 1, checkpoint: 2, anchor: NoteAnchor(checkpoint: 2, quote: "a"),
                                                old: "a", new: "b")]
        let clock = WatchClock(appIsActive: { true })
        let m = ThreadPanelModel(intakeID: intake, reader: store, pollClock: clock)
        m.refresh()                                   // the bind, with no rail or panel shown
        XCTAssertTrue(clock.isRegistered(m), "pending diffs and nothing polling")
        store.diffsByThread[t.id]!.append(ThreadDiff(thread: t.id, turn: 2, checkpoint: 2,
                                                     anchor: NoteAnchor(checkpoint: 2, quote: "c"), old: "c", new: "d"))
        clock.fire()
        XCTAssertEqual(m.pendingDiffsInPlan.count, 2)
        store.diffsByThread[t.id] = store.diffsByThread[t.id]!.map { var d = $0; d.state = .accepted; return d }
        clock.fire()
        XCTAssertFalse(clock.isRegistered(m), "nothing pending and no view: the clock is let go")
        m.start(on: clock)
        m.stop()
        XCTAssertFalse(clock.isRegistered(m))
    }

    /// M1: a thread started here that ThreadRunner never folds (a dead runner, an intake that left
    /// shaping) stops saying "answering…" after a minute, and Retry puts the words back.
    func testAStartedThreadThatNeverStartsSaysSoAfterAMinute() {
        var now = FakeThreadStore.date
        let started = ThreadID()
        let m = ThreadPanelModel(intakeID: intake, reader: store, actions: .init(open: { _, _, _, _ in .success(started) }),
                                 now: { now })
        m.beginThread(on: .wholePlan)
        m.composer = "Why?"
        m.send()
        guard case .pending(let p) = m.conversation else { return XCTFail("\(m.conversation)") }
        XCTAssertFalse(m.pendingStalled(p))
        now = now.addingTimeInterval(ThreadPanelModel.pendingTimeout + 1)
        XCTAssertTrue(m.pendingStalled(p))
        XCTAssertFalse(m.stalledStarts.contains(started))
        m.refresh()
        XCTAssertEqual(m.stalledStarts, [started], "the poll publishes the stall")
        m.retryPending(started)
        XCTAssertEqual(m.conversation, .newThread(.wholePlan))
        XCTAssertEqual(m.composer, "Why?")
    }

    /// M2: "You answered" names the picks, by their labels.
    func testYouAnsweredNamesThePicks() {
        let t = store.add("Which store?")
        let q = StructuredQuestion(id: "q1", text: "Which?", kind: .multi,
                                   options: [.init(id: "a", label: "SQLite"), .init(id: "b", label: "Files")])
        store.addTurn(t.id, reply: "Pick.", actions: [.askQuestion(q)])
        store.addTurn(t.id, answers: [StructuredAnswer(questionID: "q1", selected: ["b", "a"], other: "S3")])
        let m = model()
        m.refresh()
        XCTAssertEqual(m.answered(t.id, turn: m.turns(t.id)[1]), "Files, SQLite, and S3")
    }

    /// M5: a new thread starts with no answer picks left over from the last one.
    func testBeginThreadClearsAnswerDrafts() {
        let m = model()
        m.answerDrafts = ["q1": StructuredAnswer(questionID: "q1", selected: ["a"])]
        m.beginThread(on: .wholePlan)
        XCTAssertTrue(m.answerDrafts.isEmpty)
    }

    /// Wording: refusals the panel can get read as words, never as a code.
    func testEveryPanelRefusalReadsAsWords() {
        for code in ["unknown_checkpoint", "unknown_block", "stale_questions", "out_of_scope", "already_accepted"] {
            let words = ThreadPanelModel.words(for: ThreadRefusal(code: code))
            XCTAssertFalse(words.contains(code), "\(code): \(words)")
        }
    }

    /// B-I4: the panel's diff row says what the change is: its section and the new words.
    func testADiffRowShowsTheNewText() {
        let d = ThreadDiff(thread: ThreadID(), turn: 1, checkpoint: 2,
                           anchor: NoteAnchor(checkpoint: 2, quote: "old", section: "## 3. Revocation"),
                           old: "old", new: "Revoked tokens stop working within one second.")
        XCTAssertEqual(ThreadPanelModel.diffRowText(d), "§3 Revocation · “Revoked tokens stop working within one second.”")
    }

    /// A decision refused from anywhere is announced, so the plan's toolbar can say it too (B-I2).
    func testARefusedDecisionIsAnnounced() {
        let d = ThreadDiff(thread: ThreadID(), turn: 1, checkpoint: 2, anchor: NoteAnchor(checkpoint: 2, quote: "old"),
                           old: "old", new: "new")
        var heard: [String] = []
        let token = NotificationCenter.default.addObserver(forName: ThreadPanelModel.diffRefused, object: nil, queue: nil) { note in
            heard.append(note.userInfo?["words"] as? String ?? "")
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let m = model(.init(decide: { _, _, _, _ in ThreadRefusal(code: "diff_stale") }))
        m.decide(d, accept: true)
        XCTAssertEqual(heard, [ThreadPanelModel.words(for: ThreadRefusal(code: "diff_stale"))])
    }

    /// A-7: a reply or an answer keeps one messageID from the press that first sends it until a
    /// send lands, so pressing again (a double press, or a retry after a refusal) is the same
    /// message, and ThreadRunner runs one turn. The next draft gets a new one.
    func testADraftKeepsOneMessageIDUntilItsSendLands() {
        let t = store.add("Why?")
        store.addTurn(t.id, you: "Why?", reply: "Because.")
        var sent: [String] = [], answered: [String] = []
        var refuse = true
        let m = model(.init(send: { _, _, id in sent.append(id); return refuse ? ThreadRefusal(code: "write_failed") : nil },
                            answer: { _, _, id in answered.append(id); return refuse ? ThreadRefusal(code: "write_failed") : nil }))
        m.refresh()
        m.open(t.id)
        m.composer = "And then?"
        m.send()
        m.send()
        refuse = false
        m.send()
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(Set(sent).count, 1, "every press of one draft is one message")
        m.composer = "Another question"
        m.send()
        XCTAssertNotEqual(sent.last, sent.first, "a new draft is a new message")

        let q = StructuredQuestion(id: "q1", text: "Which?", kind: .single, options: [.init(id: "a", label: "A")])
        store.addTurn(t.id, reply: "Pick.", actions: [.askQuestion(q)])
        m.refresh()
        refuse = true
        m.answerDrafts = ["q1": StructuredAnswer(questionID: "q1", selected: ["a"])]
        m.submitAnswers(t.id)
        refuse = false
        m.submitAnswers(t.id)
        XCTAssertEqual(answered.count, 2)
        XCTAssertEqual(Set(answered).count, 1, "a retried answer is the same message")
    }

    // MARK: A thread just started

    /// Concern 2: after ✦ Ask's first send the thread exists only as a queued open until
    /// ThreadRunner folds it. The conversation shows it — its anchor, the words sent and
    /// "answering…" — never "No thread open"; once the reader has the thread, the real one replaces it.
    func testAThreadJustStartedShowsItsWordsUntilTheRunnerHasIt() {
        let started = ThreadID()
        let anchor = ThreadAnchor(note: NoteAnchor(checkpoint: 2, quote: "the opening sentence", section: "## Scope"))
        let m = model(.init(open: { _, _, _, _ in .success(started) }))
        m.refresh()
        XCTAssertEqual(m.conversation, .none)
        m.beginThread(on: anchor)
        XCTAssertEqual(m.conversation, .newThread(anchor))
        m.composer = "Why this step?\nAnd not a smaller one?"
        m.send()
        XCTAssertEqual(m.conversation, .pending(PendingThread(id: started, title: "Why this step?", anchor: anchor,
                                                              you: "Why this step?\nAnd not a smaller one?")))
        m.refresh()
        XCTAssertEqual(m.conversation, .pending(PendingThread(id: started, title: "Why this step?", anchor: anchor,
                                                              you: "Why this step?\nAnd not a smaller one?")),
                       "still queued: the runner has not folded the open")

        store.records.append(ThreadRecord(id: started, title: "Why this step?", anchor: anchor, status: .answering,
                                          agent: .claude, model: "opus", effort: "high", followsCheckpoint: 2,
                                          createdAt: FakeThreadStore.date))
        m.refresh()
        XCTAssertEqual(m.conversation, .thread(started))
        XCTAssertNil(m.pendingThread(started), "the real thread replaces the local one")
    }

    // MARK: Index

    func testIndexGroupsOpenNeedsYouAndResolved() {
        let plain = store.add("Why no expiry?", section: "## 2. Session lifetime")
        let asked = store.add("Pairing failure copy", section: "## 4. Failure modes")
        store.addTurn(asked.id, you: "?", reply: "Which one?", actions: [question()])
        let waiting = store.add("Revocation wording", section: "## 3. Revocation")
        store.addDiff(waiting.id)
        let done = store.add("Why SPAKE2?", section: "## 1. Pairing", status: .resolved)
        let flagged = store.add("Status flagged", status: .needsYou)

        let m = model()
        m.refresh()

        XCTAssertEqual(m.index.open.map(\.id), [plain.id])
        XCTAssertEqual(Set(m.index.needsYou.map(\.id)), [asked.id, waiting.id, flagged.id])
        XCTAssertEqual(m.index.resolved.map(\.id), [done.id])
    }

    func testAnAnsweredQuestionNoLongerNeedsYou() {
        let t = store.add("Pairing failure copy")
        store.addTurn(t.id, you: "?", reply: "Which?", actions: [question()])
        store.addTurn(t.id, answers: [StructuredAnswer(questionID: "q1", selected: ["a"])])
        let m = model()
        m.refresh()
        XCTAssertEqual(m.index.open.map(\.id), [t.id])
        XCTAssertTrue(m.index.needsYou.isEmpty)
    }

    func testOpenGroupFollowsPlanOrderWithWholePlanLast() {
        let late = store.add("Late", section: "## 5. Settings UI")
        let whole = store.add("Whole plan", quote: "")
        let early = store.add("Early", section: "## 2. Session lifetime")
        let m = model(headings: ["## 1. Pairing", "## 2. Session lifetime", "## 5. Settings UI"])
        m.refresh()
        XCTAssertEqual(m.index.open.map(\.id), [early.id, late.id, whole.id])
        XCTAssertEqual(m.index.open.first?.section, "§2 Session lifetime")
    }

    func testAStaleThreadWearsTheStalePillAndStaysOpen() {
        let t = store.add("Is CGNAT-first right?", section: "## 2. Session lifetime", status: .stale)
        let m = model()
        m.refresh()
        XCTAssertEqual(m.index.open.map(\.id), [t.id])
        XCTAssertEqual(m.index.open.first?.pill, .stale)
        XCTAssertEqual(m.card(for: t.id)?.pill, .stale)
        XCTAssertEqual(ThreadPill.stale.text, "stale")
    }

    func testFilterMatchesTitleAndQuoteIgnoringCase() {
        let a = store.add("Why no expiry?", quote: "Tokens never expire")
        store.add("Settings screen comp", quote: "gear icon")
        let m = model()
        m.refresh()
        m.filter = "EXPIRY"
        XCTAssertEqual(m.index.open.map(\.id), [a.id])
        m.filter = "gear"
        XCTAssertEqual(m.index.open.map(\.title), ["Settings screen comp"])
        m.filter = "   "
        XCTAssertEqual(m.index.open.count, 2)
    }

    func testTheCardCountsDiffsNotesAndMessages() {
        let t = store.add("Why?")
        store.addTurn(t.id, you: "Why?", reply: "Because", actions: [
            .addNote(PlanNote(kind: .mustChange, note: "Log it", source: .thread(t.id))),
        ])
        store.addDiff(t.id)
        store.addDiff(t.id, state: .accepted)
        let m = model()
        m.refresh()
        let card = m.card(for: t.id)
        XCTAssertEqual(card?.pendingDiffs, 1)
        XCTAssertEqual(card?.notes, 1)
        XCTAssertEqual(card?.messages, 2)
        XCTAssertEqual(card?.excerpt, "Because")
    }

    // MARK: Live activity (R2)

    func testALiveTurnShowsItsActivityAndTheAnsweringPill() {
        let t = store.add("Why?", status: .answering)
        store.live[t.id] = "reading §3"
        let m = model()
        m.refresh()
        XCTAssertEqual(m.card(for: t.id)?.activity, "reading §3")
        XCTAssertEqual(m.card(for: t.id)?.pill, .answering)
        store.live[t.id] = nil
        m.refresh()
        XCTAssertNil(m.card(for: t.id)?.activity)
    }

    // MARK: Auto-accept

    func testTheAutoAcceptSwitchSendsAndShowsAtOnce() {
        let t = store.add("Why?")
        var sent: [(ThreadID, Bool)] = []
        let m = model(.init(setAutoAccept: { sent.append(($0, $1)); return nil }))
        m.refresh()
        XCTAssertFalse(m.autoAccept(t.id))
        m.setAutoAccept(t.id, true)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.1, true)
        // The runner has not written it yet: the switch must not snap back meanwhile.
        XCTAssertTrue(m.autoAccept(t.id))
    }

    func testARefusedAutoAcceptSwitchStaysPutAndSaysWhy() {
        let t = store.add("Why?")
        let m = model(.init(setAutoAccept: { _, _ in IntakeService.unavailable }))
        m.refresh()
        m.setAutoAccept(t.id, true)
        XCTAssertFalse(m.autoAccept(t.id))
        XCTAssertEqual(m.notice, ThreadPanelModel.unavailableNotice)
    }

    func testTheStoreCatchesUpWithTheSwitch() {
        let t = store.add("Why?")
        let m = model(.init(setAutoAccept: { _, _ in nil }))
        m.refresh()
        m.setAutoAccept(t.id, true)
        store.records[0].autoAccept = true
        m.refresh()
        XCTAssertTrue(m.autoAccept(t.id))
        // And a later change made elsewhere (the phone) is not held back by the old override.
        store.records[0].autoAccept = false
        m.refresh()
        XCTAssertFalse(m.autoAccept(t.id))
    }

    // MARK: Session memory

    func testTheOpenThreadAndPanelWidthSurviveANewModelForTheSameIntake() {
        let t = store.add("Why?")
        let first = model()
        first.refresh()
        first.open(t.id)
        first.width = 600
        let second = model()
        XCTAssertEqual(second.selected, t.id)
        XCTAssertTrue(second.isOpen)
        XCTAssertEqual(second.width, 600)
        let other = model(intake: UUID())
        XCTAssertNil(other.selected)
        XCTAssertFalse(other.isOpen)
        XCTAssertNil(other.width)
        first.close()
        XCTAssertFalse(model().isOpen)
        XCTAssertEqual(model().selected, t.id, "closing the panel keeps the thread it was on")
    }

    func testPanelWidthIsClampedToTheInspectorsRange() {
        let m = model()
        m.width = 100
        XCTAssertEqual(m.width, ThreadPanelModel.widthRange.lowerBound)
        m.width = 2000
        XCTAssertEqual(m.width, ThreadPanelModel.widthRange.upperBound)
    }

    // MARK: Polling

    func testPollingPicksUpATurnTheRunnerWroteAfterTheBind() {
        let t = store.add("Why?", status: .answering)
        let m = model()
        let clock = WatchClock(appIsActive: { true })
        m.start(on: clock)
        XCTAssertTrue(clock.isRegistered(m))
        XCTAssertTrue(m.turns(t.id).isEmpty)

        store.addTurn(t.id, you: "Why?", reply: "Because of the offline requirement.")
        store.records[0].status = .open
        clock.fire()

        XCTAssertEqual(m.turns(t.id).count, 1)
        XCTAssertEqual(m.card(for: t.id)?.excerpt, "Because of the offline requirement.")
        XCTAssertNil(m.card(for: t.id)?.pill)
        m.stop()
        XCTAssertFalse(clock.isRegistered(m))
    }

    func testAStoppedModelReadsNothing() {
        store.add("Why?")
        let m = model()
        let clock = WatchClock(appIsActive: { true })
        m.start(on: clock)
        m.stop()
        let before = store.reads
        clock.fire()
        XCTAssertEqual(store.reads, before)
    }

    func testAnUnchangedStoreDoesNotRepublish() {
        store.add("Why?")
        let m = model()
        var changes = 0
        let watch = m.objectWillChange.sink { changes += 1 }
        m.refresh()
        let after = changes
        m.refresh()
        m.refresh()
        XCTAssertEqual(changes, after, "a poll that finds nothing new must not redraw the rail")
        watch.cancel()
    }

    // MARK: Composer

    func testSendingOnANewThreadOpensItAndSelectsIt() {
        var opened: [(ThreadAnchor, String, String)] = []
        let id = ThreadID()
        let m = model(.init(open: { anchor, title, text, _ in opened.append((anchor, title, text)); return .success(id) }))
        let anchor = ThreadAnchor(note: NoteAnchor(checkpoint: 2, quote: "Tokens never expire"))
        m.beginThread(on: anchor)
        XCTAssertTrue(m.isOpen)
        XCTAssertTrue(m.isComposingNewThread)
        m.composer = "Why do tokens never expire? That feels risky."
        m.send()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, anchor)
        XCTAssertEqual(opened.first?.2, "Why do tokens never expire? That feels risky.")
        XCTAssertEqual(opened.first?.1, "Why do tokens never expire? That feels risky.")
        XCTAssertEqual(m.selected, id)
        XCTAssertFalse(m.isComposingNewThread)
        XCTAssertEqual(m.composer, "")
    }

    func testALongFirstMessageGivesAShortTitle() {
        XCTAssertEqual(ThreadPanelModel.title(from: "Short one\nwith a second line"), "Short one")
        let long = String(repeating: "word ", count: 30)
        let title = ThreadPanelModel.title(from: long)
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testSendAndResolveSendsThenResolves() {
        let t = store.add("Why?")
        var calls: [String] = []
        let m = model(.init(send: { _, text, _ in calls.append("send \(text)"); return nil },
                            resolve: { _ in calls.append("resolve"); return nil }))
        m.refresh()
        m.open(t.id)
        m.composer = "Thanks, that settles it."
        m.send(andResolve: true)
        XCTAssertEqual(calls, ["send Thanks, that settles it.", "resolve"])
        XCTAssertEqual(m.composer, "")
    }

    func testARefusedSendKeepsWhatTheHumanTyped() {
        let t = store.add("Why?")
        let m = model(.init(send: { _, _, _ in IntakeService.unavailable }))
        m.refresh()
        m.open(t.id)
        m.composer = "Words I do not want to lose"
        m.send()
        XCTAssertEqual(m.composer, "Words I do not want to lose")
        XCTAssertEqual(m.notice, ThreadPanelModel.unavailableNotice)
    }

    func testAnEmptyComposerSendsNothing() {
        let t = store.add("Why?")
        var sends = 0
        let m = model(.init(send: { _, _, _ in sends += 1; return nil }))
        m.refresh()
        m.open(t.id)
        m.composer = "  \n "
        m.send()
        XCTAssertEqual(sends, 0)
    }

    // MARK: ⌘[ and ⌘]

    func testSwitchingThreadsWalksTheIndexInDisplayOrder() {
        let a = store.add("A", section: "## 1. One")
        let b = store.add("B", section: "## 2. Two")
        let c = store.add("C", status: .resolved)
        let m = model(headings: ["## 1. One", "## 2. Two"])
        m.refresh()
        m.open(a.id)
        m.switchThread(by: 1)
        XCTAssertEqual(m.selected, b.id)
        m.switchThread(by: 1)
        XCTAssertEqual(m.selected, c.id)
        m.switchThread(by: 1)
        XCTAssertEqual(m.selected, a.id, "wraps")
        m.switchThread(by: -1)
        XCTAssertEqual(m.selected, c.id)
    }

    // MARK: Header

    func testTheHeaderNamesTheAgentAndTheVersionTheThreadFollows() {
        let t = store.add("Why?", follows: 3)
        let m = model()
        m.versionLabel = { $0 == 3 ? "Refine 2" : nil }
        m.refresh()
        let header = m.header(for: t.id)
        XCTAssertEqual(header?.agent, "claude · opus · high")
        XCTAssertEqual(header?.follows, "on Refine 2")
        XCTAssertEqual(header?.quote, "a quote")
    }

    func testThreadsCountExcludesResolved() {
        store.add("Open one")
        store.add("Done", status: .resolved)
        let m = model()
        m.refresh()
        XCTAssertEqual(m.liveCount, 1)
    }

    func testDecisionsGoThroughTheSendAPI() {
        let t = store.add("Why?")
        let diff = ThreadDiff(thread: t.id, checkpoint: 2, anchor: NoteAnchor(checkpoint: 2, quote: "x"), old: "x", new: "y")
        var decided: [(UUID, Bool)] = []
        var reproposed: [UUID] = []
        let m = model(.init(decide: { _, d, accept, _ in decided.append((d, accept)); return nil },
                            repropose: { _, d in reproposed.append(d); return nil }))
        m.decide(diff, accept: true)
        m.decide(diff, accept: false)
        m.repropose(diff)
        XCTAssertEqual(decided.map(\.1), [true, false])
        XCTAssertEqual(decided.first?.0, diff.id)
        XCTAssertEqual(reproposed, [diff.id])
    }

    // MARK: Edit, then Accept (fix round 1)

    func testAcceptEditedSendsTheEditedPlanAsAnAccept() {
        let t = store.add("Why?")
        let diff = ThreadDiff(thread: t.id, checkpoint: 2, anchor: NoteAnchor(checkpoint: 2, quote: "x"), old: "x", new: "y")
        var seen: [(Bool, String?)] = []
        let m = model(.init(decide: { _, _, accept, edited in seen.append((accept, edited)); return nil }))
        m.decide(diff, accept: true, editedMarkdown: "# Plan\n\nthe words as the human changed them")
        m.decide(diff, accept: true)
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].0, true, "an edited accept is recorded as an accept, never a rejection")
        XCTAssertEqual(seen[0].1, "# Plan\n\nthe words as the human changed them")
        XCTAssertNil(seen[1].1)
    }

    // MARK: Agent defaults and menu (D8)

    func testANewThreadAsksWhatTheDefaultsProviderSays() {
        var asked: [ThreadDefaults] = []
        let chosen = ThreadDefaults(agent: .codex, model: "gpt-x", effort: "xhigh")
        let m = ThreadPanelModel(intakeID: intake, reader: store,
                                 actions: .init(open: { _, _, _, d in asked.append(d); return .success(ThreadID()) }),
                                 defaultsProvider: { chosen })
        m.beginThread(on: .wholePlan)
        m.composer = "hello"
        m.send()
        XCTAssertEqual(asked, [chosen])
    }

    func testTheHeaderMenuComesFromTheModelMenuAndMovesTheThread() {
        let t = store.add("Why?")
        let menu = [ThreadAgentChoice(agent: .claude, model: "opus", modelName: "Opus", effort: "high"),
                    ThreadAgentChoice(agent: .grok, model: "grok-4", modelName: "Grok 4", effort: "high")]
        var moved: [ThreadAgentChoice] = []
        let m = ThreadPanelModel(intakeID: intake, reader: store, actions: .init(setAgent: { _, c in moved.append(c); return nil }),
                                 modelMenu: { menu })
        XCTAssertEqual(m.agentChoices, menu)
        m.setAgent(t.id, menu[1])
        XCTAssertEqual(moved, [menu[1]])
        XCTAssertFalse(menu[0].readsFilesOnly)
        XCTAssertTrue(menu[1].readsFilesOnly)
        XCTAssertTrue(ThreadAgentChoice(agent: .opencode, model: "", modelName: "", effort: "").readsFilesOnly)
    }

    func testTheHeaderSaysWhenTheAgentOnlyReadsFiles() {
        let t = store.add("Why?")
        store.records[0].agent = .grok
        let m = model()
        m.refresh()
        XCTAssertEqual(m.header(for: t.id)?.readsFilesOnly, true)
    }

    // MARK: Keys, polling lifecycle, refusals

    func testBracketKeysSwitchThreadsOnlyWithCommand() {
        XCTAssertEqual(ThreadPanelModel.switchStep(key: "[", command: true), -1)
        XCTAssertEqual(ThreadPanelModel.switchStep(key: "]", command: true), 1)
        XCTAssertNil(ThreadPanelModel.switchStep(key: "[", command: false))
        XCTAssertNil(ThreadPanelModel.switchStep(key: "a", command: true))
    }

    func testSwappingTheRailForThePanelDoesNotStopThePolling() {
        let m = model()
        let clock = WatchClock(appIsActive: { true })
        m.start(on: clock)           // the rail appears
        m.start(on: clock)           // the panel appears
        m.stop()                     // the rail goes
        XCTAssertTrue(clock.isRegistered(m), "the panel is still on screen")
        m.stop()
        XCTAssertFalse(clock.isRegistered(m))
        m.stop()                     // an extra stop does not go negative
        m.start(on: clock)
        XCTAssertTrue(clock.isRegistered(m))
        m.stop()
    }

    func testQuestionsAreWorkedOutOncePerRefresh() {
        let asked = store.add("Pairing failure copy")
        store.addTurn(asked.id, you: "?", reply: "Which?", actions: [question()])
        let m = model()
        m.refresh()
        let reads = store.turnReads
        for _ in 0..<5 { _ = m.openQuestions(asked.id); _ = m.index; _ = m.card(for: asked.id) }
        XCTAssertEqual(store.turnReads, reads, "asking again must not read the store again")
        XCTAssertEqual(m.openQuestions(asked.id).count, 1)
    }

    /// The notes controller tells the editor when the panel moves to another thread (`$selected`),
    /// so a half-made Edit on the last thread is let go; the same thread again, and the first
    /// binding, are not a switch.
    func testThePanelMovingToAnotherThreadIsReportedOnce() async throws {
        let controller = PlanNotesController()
        var switched = 0
        controller.onThreadSwitched = { switched += 1 }
        controller.threads = IntakeThreadBinding(intakeID: UUID(), reader: EmptyThreadStore(), service: nil)
        let panel = try XCTUnwrap(controller.threadPanel)
        let a = ThreadID(), b = ThreadID()
        panel.open(a)
        panel.open(a)
        panel.open(b)
        // The controller hops to the next main-actor turn before it calls out.
        for _ in 0..<20 where switched < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(switched, 2)
    }

    func testRefusalsReadAsWordsNotCodes() {
        for code in ["unknown_thread", "unknown_diff", "diff_stale", "empty_message", "not_allowed", "no_agents"] {
            let words = ThreadPanelModel.words(for: ThreadRefusal(code: code))
            XCTAssertFalse(words.contains("_"), "\(code) leaked into \(words)")
            XCTAssertTrue(words.hasSuffix("."))
        }
        XCTAssertEqual(ThreadPanelModel.words(for: ThreadRefusal(code: "threads_unavailable")), ThreadPanelModel.unavailableNotice)
        XCTAssertTrue(ThreadPanelModel.words(for: ThreadRefusal(code: "weird_new_code")).contains("weird_new_code"),
                      "an unknown code keeps its code, for whoever is diagnosing")
    }
}

final class ThreadCitationTests: XCTestCase {
    func testCitationsBecomeChipsBetweenText() {
        let parts = ThreadCitation.split("Because the intake says so [cite:intake]. The draft [cite:ckpt:1] agreed.")
        XCTAssertEqual(parts, [
            .text("Because the intake says so "), .cite(.intake),
            .text(". The draft "), .cite(.checkpoint(1)), .text(" agreed."),
        ])
    }

    func testEachKindOfCitationIsRecognised() {
        XCTAssertEqual(ThreadCitation.parse("intake"), .intake)
        XCTAssertEqual(ThreadCitation.parse("ckpt:3"), .checkpoint(3))
        XCTAssertEqual(ThreadCitation.parse("issue:r1-4"), .issue("r1-4"))
        XCTAssertEqual(ThreadCitation.parse("HostKit/ControllerStore.swift:88"), .file(path: "HostKit/ControllerStore.swift", line: 88))
    }

    func testAnIdThatMatchesNothingIsPlainText() {
        // Spec §5: a citation that matches no workspace id is never a link.
        XCTAssertNil(ThreadCitation.parse("made-up-thing"))
        XCTAssertEqual(ThreadCitation.split("see [cite:made-up-thing] here"), [.text("see made-up-thing here")])
    }

    func testChipLabelsAreShort() {
        XCTAssertEqual(ThreadCitation.file(path: "HostKit/ControllerStore.swift", line: 88).label, "ControllerStore.swift:88")
        XCTAssertEqual(ThreadCitation.checkpoint(2).label, "checkpoint 2")
        XCTAssertEqual(ThreadCitation.intake.label, "intake")
    }
}
