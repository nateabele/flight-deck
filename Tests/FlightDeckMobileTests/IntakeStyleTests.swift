import FleetKit
import XCTest
@testable import FlightDeckMobile

final class IntakeStyleTests: XCTestCase {
    private func s(_ state: String, attention: Bool = false, now: String? = nil, run: String? = nil,
                   created: Double = 0, questions: Int? = nil, released: Int? = nil,
                   done: Int? = nil, total: Int? = nil) -> WireIntakeSummary {
        WireIntakeSummary(id: UUID(), title: "T", state: state, needsAttention: attention, now: now,
                          runStatus: run, agentsDone: done, agentsTotal: total, questionCount: questions,
                          releasedTaskCount: released, createdAt: Date(timeIntervalSinceReferenceDate: created))
    }

    func testRowsOrderNeedsYouThenFlyingThenTheRestNewestFirst() {
        let old = s("released", created: 1), attention = s("needsAnswers", attention: true, created: 2),
            running = s("shaping", run: "running", created: 3), paused = s("shaping", run: "paused", created: 4),
            newer = s("released", created: 5)
        XCTAssertEqual(IntakeRowStyle.ordered([old, attention, running, paused, newer]).map(\.id),
                       [attention.id, paused.id, running.id, newer.id, old.id])
    }

    func testTheBadgeCountsNeedsYouAndIsAbsentAtZero() {
        XCTAssertEqual(IntakeRowStyle.badge([s("review", attention: true), s("needsAnswers", attention: true), s("shaping")]), "2 need you")
        XCTAssertEqual(IntakeRowStyle.badge([s("review", attention: true)]), "1 needs you")
        XCTAssertNil(IntakeRowStyle.badge([s("shaping")]))
        XCTAssertNil(IntakeRowStyle.badge(nil))
    }

    func testFactsSayWhatTheRowIsWaitingOn() {
        XCTAssertEqual(IntakeRowStyle.fact(s("needsAnswers", attention: true, questions: 3), clock: nil), "3 questions")
        XCTAssertEqual(IntakeRowStyle.fact(s("needsAnswers", attention: true, questions: 1), clock: nil), "1 question")
        XCTAssertEqual(IntakeRowStyle.fact(s("released", released: 6), clock: nil), "Released 6 tasks")
        XCTAssertEqual(IntakeRowStyle.fact(s("shaping", now: "Refine 2", run: "running", done: 1, total: 2), clock: "4:12"),
                       "Refine 2 · 4:12 · 1 of 2 agents")
    }

    func testPresetNamesSayTaskNeverBead() {
        XCTAssertEqual(IntakeRowStyle.presetName("bead"), "Single task")
        XCTAssertEqual(IntakeRowStyle.presetName("featurePlan"), "Feature plan")
        XCTAssertEqual(IntakeRowStyle.presetName("fullPlan"), "Full plan")
        XCTAssertEqual(IntakeRowStyle.presetName("sketch"), "Sketch")
        XCTAssertNil(IntakeRowStyle.presetName(nil))
    }

    func testGlyphsColourOnlyExceptions() {
        XCTAssertEqual(IntakeRowStyle.glyph(s("needsAnswers", attention: true)).tone, .attention)
        XCTAssertEqual(IntakeRowStyle.glyph(s("failed", attention: true)).tone, .failure)
        XCTAssertEqual(IntakeRowStyle.glyph(s("shaping", run: "running")).tone, .live)
        XCTAssertEqual(IntakeRowStyle.glyph(s("released")).tone, .quiet)
    }

    func testAnUnknownStateRendersDegradedNotBlank() {
        XCTAssertFalse(IntakeRowStyle.pill(s("someFutureState")).isEmpty)
    }

    // MARK: Banner (Review Focus #3)

    func testABannerFiresOnlyOnATransitionIntoNeedsYou() {
        let before = s("triaging")
        var after = before; after.state = "needsAnswers"; after.needsAttention = true; after.questionCount = 3
        XCTAssertEqual(BannerPolicy.banners(previous: [before.id: before], next: [after], project: "larkOS", onScreen: nil),
                       [IntakeBanner(id: after.id, project: "larkOS", title: "T needs answers", subtitle: "larkOS · 3 questions")])
        XCTAssertEqual(BannerPolicy.banners(previous: [after.id: after], next: [after], project: "larkOS", onScreen: nil), [],
                       "already waiting: no banner")
        XCTAssertEqual(BannerPolicy.banners(previous: [:], next: [after], project: "larkOS", onScreen: nil), [],
                       "never seen before (a snapshot, a reconnect): no banner")
        XCTAssertEqual(BannerPolicy.banners(previous: [before.id: before], next: [after], project: "larkOS", onScreen: after.id), [],
                       "its own screen is open: no banner")
    }

    func testBannerWordsPerState() {
        let base = s("triaging")
        for (state, words) in [("review", "is ready for review"), ("awaitingChoice", "is ready to plan"),
                               ("failed", "failed"), ("interrupted", "was interrupted"), ("shaping", "is paused")] {
            var next = base; next.state = state; next.needsAttention = true
            XCTAssertEqual(BannerPolicy.banners(previous: [base.id: base], next: [next], project: "p", onScreen: nil).first?.title,
                           "T \(words)")
        }
    }

    // MARK: Clock (Review Focus #1)

    func testSkewedClockNeverGoesNegative() {
        let since = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertEqual(ClockPolicy.elapsed(since: since, now: Date(timeIntervalSinceReferenceDate: 95), offset: 0, frozenAt: nil), 0)
        XCTAssertEqual(ClockPolicy.elapsed(since: since, now: Date(timeIntervalSinceReferenceDate: 95), offset: 10, frozenAt: nil), 5)
    }

    func testADisconnectedClockFreezes() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(ClockPolicy.elapsed(since: since, now: Date(timeIntervalSinceReferenceDate: 500), offset: 0,
                                           frozenAt: Date(timeIntervalSinceReferenceDate: 60)), 60)
    }

    func testClockTextAndIdleTicks() {
        XCTAssertEqual(ClockPolicy.text(0), "0:00")
        XCTAssertEqual(ClockPolicy.text(252), "4:12")
        XCTAssertEqual(ClockPolicy.text(3723), "1:02:03")
        XCTAssertEqual(ClockPolicy.tickInterval(elapsed: 30, idle: true), 1)
        XCTAssertEqual(ClockPolicy.tickInterval(elapsed: 61, idle: true), 60)
        XCTAssertEqual(ClockPolicy.tickInterval(elapsed: 600, idle: false), 1)
    }
}
