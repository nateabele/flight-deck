import FleetKit
import XCTest
@testable import FlightDeck

/// A read that follows a keystroke must describe the screen that keystroke made.
///
/// **This is the bug these tests exist for.** `readViewport()` is served from a `CachedValue`
/// that holds a screen for 500ms, and the answer drive presses a key, waits 120ms for the
/// repaint and reads back to confirm the cursor moved. Those numbers do not compose: the
/// re-read could be answered from before the press, so the drive saw the marker on the row it
/// had just left, concluded the key never landed, and abandoned a dialog with one box already
/// ticked — intermittently, because it depends where the press fell in the cache's lifetime.
/// The fix is that whoever types drops the entry, so only reads after an injection re-fetch
/// and the pollers keep their cache.
///
/// The drives below run against `SpyInjector.cacheViewport()`, which puts the production
/// `CachedValue` in front of the fake's screen with a duration no test can outlive. Take the
/// invalidation away — `clearedByInjection: false`, the third test — and they abort exactly
/// where the real drive did.
@MainActor
final class ViewportFreshnessTests: XCTestCase {
    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    /// A class so the sink closure and the test read the same array.
    private final class Recorder {
        var aborts: [AnswerAbort] = []
    }

    private func entry(_ sid: UUID, cwd: String) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: .waiting, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// The waiting claude tab `AnswerPromptTests` and `AnswerDiagnosticsTests` build, with the
    /// abort sink captured — because "no abort was filed" is half of what is asserted here.
    private func makeStore() -> (SessionStore, SpyInjector, UUID, Recorder) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let recorder = Recorder()
        store.answerAbortSink = { recorder.aborts.append($0) }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id, recorder)
    }

    private func question(_ text: String, _ labels: [String]) -> PromptQuestion {
        PromptQuestion(header: "Pick", question: text, options: labels.map { .init(label: $0) })
    }

    private func answer(_ questions: [PromptQuestion], _ chosen: [[Int]]) -> PromptAnswer {
        .answers(zip(questions, chosen).map { question, picks in
            picks.map { AnswerSelection(index: $0, label: question.options[$0].label) }
        })
    }

    // MARK: The drive

    /// **The captured failure, with the cache in place.** Two questions, the first answered on
    /// its second row, so the drive has to arrow, re-read, press, and then find question two
    /// where question one was. Every one of those reads follows a keystroke of its own.
    ///
    /// Served from a stale cache the first re-read says the marker never moved and the drive
    /// stops after one arrow; served fresh it walks all three steps and commits on the review.
    func testASetIsDrivenToItsCommitWithTheScreenServedFromACache() {
        let (store, spy, id, log) = makeStore()
        let questions = [question("Which language?", ["Rust", "Go"]),
                         question("Which editor?", ["Vim", "Emacs"])]
        spy.showOptions(["Rust", "Go"])
        // The review's two rows verbatim from `question-two-review.captured.txt`, and both are
        // needed: a lone row is not a numbered list, and `ChoiceDialog` refuses to read one.
        spy.advanceOnReturn(to: [["Vim", "Emacs"], [AnswerPlan.submitAnswersLabel, "Cancel"]])
        spy.cacheViewport()
        XCTAssertNotNil(spy.readViewport(), "prime the cache, as any poller would have")

        store.answerPrompt(.question(callID: "toolu_A", questions),
                           with: answer(questions, [[1], [0]]), in: id, token: UUID())

        XCTAssertEqual(spy.events, [.arrow(1), .ret, .ret, .ret],
                       "one move for Go, then a press per screen: question, question, review")
        XCTAssertTrue(log.aborts.isEmpty, "and nothing refused along the way")
    }

    /// The same freshness, on the one-step `.option` path, which composes its own confirmation
    /// rather than walking a plan — a second reader of the screen, with the same hazard.
    func testTheOneStepDriveConfirmsAgainstTheScreenItsArrowsMade() {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"])
        spy.cacheViewport()
        XCTAssertNotNil(spy.readViewport())

        store.answerPrompt(
            .question(callID: "toolu_A", [question("Which?", ["Yes", "No", "Maybe"])]),
            with: .option(index: 2, label: "Maybe"), in: id, token: UUID()
        )

        XCTAssertEqual(spy.events, [.arrow(1), .arrow(1), .ret])
        XCTAssertTrue(log.aborts.isEmpty)
    }

    /// **The bug itself, reproduced.** The same drive as above against a cache no keystroke
    /// clears: the arrows go out, the marker really moves, and the re-read is answered from
    /// before the press — so the drive reports the cursor still on row 0 and sends no Return.
    ///
    /// This is what makes the two tests above falsifiable. Without it they would pass against
    /// a fake that simply had no cache and would prove nothing about a stale one.
    func testADriveReadingACacheNoKeystrokeClearsRefusesAfterTheMove() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"])
        spy.cacheViewport(clearedByInjection: false)
        XCTAssertNotNil(spy.readViewport())

        store.answerPrompt(
            .question(callID: "toolu_A", [question("Which?", ["Yes", "No", "Maybe"])]),
            with: .option(index: 2, label: "Maybe"), in: id, token: UUID()
        )

        XCTAssertEqual(spy.selected, 2, "the keystrokes landed — this is a reading fault")
        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .landingAfterMove)
        XCTAssertEqual(abort.focused, 0, "the marker as the screen from before the arrows had it")
        XCTAssertEqual(abort.to, 2)
        XCTAssertFalse(spy.events.contains(.ret), "and no Return on a row nobody chose")
    }

    // MARK: The cache itself

    /// `get()` really caches — the premise everything above rests on, and the reason a drive
    /// could read the past at all.
    func testAValueIsFetchedOnceAndServedAgain() {
        var fetches = 0
        let cache = CachedValue(duration: .seconds(3600)) { fetches += 1; return fetches }
        XCTAssertEqual(cache.get(), 1)
        XCTAssertEqual(cache.get(), 1)
        XCTAssertEqual(fetches, 1)
    }

    func testInvalidatingMakesTheNextReadFetchAgain() {
        var fetches = 0
        let cache = CachedValue(duration: .seconds(3600)) { fetches += 1; return fetches }
        XCTAssertEqual(cache.get(), 1)
        cache.invalidate()
        XCTAssertEqual(cache.get(), 2, "the entry was dropped, not merely refreshed on a timer")
        XCTAssertEqual(cache.get(), 2, "and the new value is cached like any other")
    }

    /// Invalidating something never read is a no-op rather than a fetch: the injector calls it
    /// on every keystroke, including the ones nobody reads back.
    func testInvalidatingBeforeAnyReadCostsNothing() {
        var fetches = 0
        let cache = CachedValue(duration: .seconds(3600)) { fetches += 1; return fetches }
        cache.invalidate()
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(cache.get(), 1)
    }

    /// **The pollers keep their cache.** `invalidate()` cancels the pending expiry, so the
    /// obvious way to get this wrong is to leave the entry immortal afterwards. The TTL still
    /// runs on the value stored after an invalidation.
    func testTheEntryStoredAfterAnInvalidationStillExpiresOnItsOwn() async {
        var fetches = 0
        let cache = CachedValue(duration: .milliseconds(50)) { fetches += 1; return fetches }
        XCTAssertEqual(cache.get(), 1)
        cache.invalidate()
        XCTAssertEqual(cache.get(), 2)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(cache.get(), 3, "the 50ms entry expired without anyone invalidating it")
    }
}
