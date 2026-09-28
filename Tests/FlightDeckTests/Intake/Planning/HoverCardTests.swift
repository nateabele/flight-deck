import IntakeKit
import XCTest
@testable import FlightDeck

/// The hover card is the exception to "flap once" (spec §5.3): opening it is a reveal, so its
/// full name flips in every time it opens — quickly — while the board's own labels keep flapping
/// once per new text.
@MainActor
final class CardRevealTests: XCTestCase {
    /// The root cause of "the hover card doesn't animate": the board seeded every slot's card
    /// surface (`card.<slot>`) as already shown when the tape was first observed, so the card's
    /// tiles asked `FlapPolicy`, heard "shown", and drew in place on every hover. A card surface
    /// must not be in the board's seed list at all — the card no longer asks the policy.
    func testTheBoardSeedsNoCardSurface() throws {
        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = .shaping
        let config = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        intake.roundConfig = config
        let board = BoardModel(intake: intake, tape: Tape(), config: config, now: Date(), selected: nil, preview: nil)
        XCTAssertFalse(board.flapTexts.isEmpty)
        XCTAssertEqual(board.flapTexts.keys.filter { $0.hasPrefix("card.") }, [])
    }

    /// Every open flaps, however often the same card is opened — and never under Reduce Motion.
    func testEveryOpenFlapsUnlessReduceMotion() {
        XCTAssertTrue(CardReveal.flaps(reduceMotion: false))
        XCTAssertTrue(CardReveal.flaps(reduceMotion: false), "a re-open is a reveal too")
        XCTAssertFalse(CardReveal.flaps(reduceMotion: true))
    }

    /// The board's own labels keep the once-per-text rule alongside it.
    func testBoardLabelsStillFlapOnce() {
        let policy = FlapPolicy()
        XCTAssertTrue(policy.shouldFlap(surface: "refine-2", text: "Refine 2", reduceMotion: false))
        XCTAssertFalse(policy.shouldFlap(surface: "refine-2", text: "Refine 2", reduceMotion: false))
    }

    /// Quick whatever the length: ~250–350 ms end to end, staggered left to right.
    func testTheRevealIsShortAndStaggered() {
        for count in [1, 3, 8, 16, 40] {
            XCTAssertLessThanOrEqual(CardReveal.duration(count: count), 0.35 + 1e-9, "\(count) characters")
        }
        XCTAssertGreaterThanOrEqual(CardReveal.duration(count: 8), 0.25)
        XCTAssertGreaterThan(CardReveal.stagger(count: 8), 0)
        // Mid-reveal: the first tile is further along than the last.
        let mid = CardReveal.duration(count: 8) / 2
        XCTAssertGreaterThan(CardReveal.progress(index: 0, count: 8, elapsed: mid),
                             CardReveal.progress(index: 7, count: 8, elapsed: mid))
    }

    /// Each tile starts hidden (edge-on) and lands exactly flat, and stays there.
    func testTileProgressRunsZeroToOne() {
        XCTAssertEqual(CardReveal.progress(index: 3, count: 8, elapsed: 0), 0)
        XCTAssertEqual(CardReveal.progress(index: 7, count: 8, elapsed: CardReveal.duration(count: 8)), 1, accuracy: 1e-9)
        XCTAssertEqual(CardReveal.progress(index: 0, count: 8, elapsed: 5), 1)
        var last = -1.0
        for step in 0...20 {
            let p = CardReveal.progress(index: 2, count: 8, elapsed: Double(step) * 0.02)
            XCTAssertGreaterThanOrEqual(p, last)
            last = p
        }
    }
}

/// Tooltip-style intent for hover cards: a pointer passing over the tape opens nothing; resting
/// ~350 ms on an item does; once a card is up, the next item's opens at once (warm), until the
/// pointer has been off every item for the cool-down. Timer-free: the driver calls `advance`.
final class HoverIntentTests: XCTestCase {
    func testOpensOnlyAfterTheIntentDelay() {
        var intent = HoverIntent()
        intent.enter("a", at: 10)
        XCTAssertNil(intent.shown)
        XCTAssertEqual(intent.deadline, 10 + HoverIntent.delay)
        intent.advance(to: 10 + HoverIntent.delay - 0.01)
        XCTAssertNil(intent.shown, "not yet")
        intent.advance(to: 10 + HoverIntent.delay)
        XCTAssertEqual(intent.shown, "a")
        XCTAssertNil(intent.deadline, "nothing more to wait for")
    }

    /// Sweeping along the tape: each slot is under the pointer for less than the delay, so no
    /// card opens anywhere along the way.
    func testPassingAcrossOpensNothing() {
        var intent = HoverIntent()
        var t = 0.0
        for id in ["a", "b", "c", "d"] {
            intent.enter(id, at: t)
            t += 0.12
            intent.advance(to: t)
            intent.exit(id, at: t)
            XCTAssertNil(intent.shown, id)
        }
        XCTAssertNil(intent.deadline)
    }

    /// Warm: with a card up, the neighbour's opens immediately — whichever order the exit and
    /// the enter arrive in.
    func testWarmSwitchIsImmediateInEitherEventOrder() {
        var enterFirst = HoverIntent()
        enterFirst.enter("a", at: 0)
        enterFirst.advance(to: 1)
        enterFirst.enter("b", at: 2)
        XCTAssertEqual(enterFirst.shown, "b")
        enterFirst.exit("a", at: 2)
        XCTAssertEqual(enterFirst.shown, "b", "a's late exit doesn't close b")

        var exitFirst = HoverIntent()
        exitFirst.enter("a", at: 0)
        exitFirst.advance(to: 1)
        exitFirst.exit("a", at: 2)
        XCTAssertNil(exitFirst.shown)
        exitFirst.enter("b", at: 2.1)
        XCTAssertEqual(exitFirst.shown, "b")
    }

    func testWarmthCoolsDown() {
        var intent = HoverIntent()
        intent.enter("a", at: 0)
        intent.advance(to: 1)
        intent.exit("a", at: 2)
        intent.enter("b", at: 2 + HoverIntent.coolDown + 0.01)
        XCTAssertNil(intent.shown, "cold again: b waits out the delay")
        intent.advance(to: 2 + HoverIntent.coolDown + 0.01 + HoverIntent.delay)
        XCTAssertEqual(intent.shown, "b")
    }

    /// A click, Esc, scroll or window change closes the card, and it stays closed while the
    /// pointer sits where it was — no warm reopen, no pending timer.
    func testDismissLatchesUntilTheNextEnter() {
        var intent = HoverIntent()
        intent.enter("a", at: 0)
        intent.advance(to: 1)
        intent.dismiss()
        XCTAssertNil(intent.shown)
        XCTAssertNil(intent.deadline)
        intent.advance(to: 5)
        XCTAssertNil(intent.shown)
        intent.enter("b", at: 5.1)
        XCTAssertNil(intent.shown, "not warm after a dismiss")
        intent.advance(to: 5.1 + HoverIntent.delay)
        XCTAssertEqual(intent.shown, "b")
    }

    /// Leaving before the delay cancels the pending open.
    func testLeavingCancelsThePendingOpen() {
        var intent = HoverIntent()
        intent.enter("a", at: 0)
        intent.exit("a", at: 0.2)
        XCTAssertNil(intent.deadline)
        intent.advance(to: 1)
        XCTAssertNil(intent.shown)
    }
}
