import Combine
import FleetKit
import XCTest
@testable import FlightDeck

/// `SessionStatus.answerless` — the debounced signal `derivedOpenPromptCalls` writes onto a
/// `waiting` tab once its own dialog derivation has refused `"prompt_changed"` continuously for
/// `SessionStore.stuckPromptReportLadder`'s first rung (5s). See `SessionStoreStuckPromptTests`
/// for the ladder/log this reuses the episode of; this file owns the field itself.
///
/// **A bare store with its own `openPromptProbe`, not `FleetTestHarness`'s real
/// `PromptService`.** Two of these tests are about the derivation's own dispatch —
/// `"unsupported_agent"` alongside `"prompt_changed"` — which a real claude-backed transcript
/// has no way to produce; a store that answers exactly what the test asks is the only way to
/// drive that branch at all.
@MainActor
final class SessionStoreAnswerlessTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 2_000_000)

    private func makeStore(
        probe: @escaping (UUID) -> Result<String, TimelineErrorCode>?
    ) -> (SessionStore, UUID) {
        let store = SessionStore(provider: nil, persistence: nil)
        store.now = { [weak self] in self?.clock ?? Date() }
        store.openPromptProbe = probe
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        return (store, session.id)
    }

    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    /// One beat short of the debounce — the ordinary race `stuckPromptEpisodes` was built to
    /// stay quiet through, restated for the field this episode now also drives.
    func testAnswerlessIsFalseBeforeFiveSeconds() {
        let (store, id) = makeStore(probe: { _ in .failure("prompt_changed") })
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        advance(4)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        XCTAssertFalse(store.status(for: id)?.answerless ?? true)
    }

    /// The debounce's own threshold, exactly — `stuckPromptReportLadder`'s first rung, and the
    /// same tick `checkStuckPrompts` files its first `.stuck` record for this episode (see that
    /// test class's `testAStuckEpisodeEmitsExactlyOneRecordPerRung`, at the same 5s mark).
    func testAnswerlessIsTrueAtFiveSeconds() {
        let (store, id) = makeStore(probe: { _ in .failure("prompt_changed") })
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        advance(5)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        XCTAssertTrue(store.status(for: id)?.answerless ?? false)
    }

    /// The instant a real call is nameable again, `answerless` drops — no lingering latch, the
    /// same tick the episode itself clears.
    func testAnswerlessResetsTheInstantARealCallIsFound() {
        var nameable = false
        let (store, id) = makeStore(probe: { _ in
            nameable ? .success("toolu_X") : .failure("prompt_changed")
        })
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        advance(5)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        XCTAssertTrue(store.status(for: id)?.answerless ?? false, "the debounce must have fired")

        nameable = true
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        XCTAssertFalse(store.status(for: id)?.answerless ?? true)
    }

    /// Leaving `waiting` clears it too — the other half of the reset `checkStuckPrompts`'s own
    /// episode has always honored.
    func testAnswerlessResetsWhenActivityLeavesWaiting() {
        let (store, id) = makeStore(probe: { _ in .failure("prompt_changed") })
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        advance(5)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        XCTAssertTrue(store.status(for: id)?.answerless ?? false, "the debounce must have fired")

        store.applyRegistryForTesting([id: SessionStatus(activity: .busy)])
        XCTAssertFalse(store.status(for: id)?.answerless ?? true)
    }

    /// `"unsupported_agent"` means this build cannot even ask — a dialog might be genuinely
    /// open and simply unreadable, which is a different sentence than "nothing is open", and
    /// must never earn `answerless` no matter how long it persists.
    func testAnswerlessStaysFalseForUnsupportedAgentNoMatterHowLong() {
        let (store, id) = makeStore(probe: { _ in .failure("unsupported_agent") })
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        advance(30)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        XCTAssertFalse(store.status(for: id)?.answerless ?? true)
    }

    /// Any other refusal code is the same story as `"unsupported_agent"`: only the specific
    /// `"prompt_changed"` refusal is this Mac asserting there is nothing open.
    func testAnswerlessStaysFalseForOtherFailureCodes() {
        let (store, id) = makeStore(probe: { _ in .failure("not_waiting") })
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        advance(30)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        XCTAssertFalse(store.status(for: id)?.answerless ?? true)
    }

    /// **The regression a review caught.** `commitStatuses` assigns `statuses` twice a tick —
    /// once before `derivedOpenPromptCalls` runs (so `PromptService.openPrompt`'s own read of
    /// `store.status(for:)` sees this tick's fresh activity), once after (so the field that
    /// derivation just filled in reaches `statuses` at all). Every caller builds `next` fresh
    /// with `answerless: false`, with no way to know an ongoing episode's real value — so
    /// without seeding `next[id].answerless` from the CURRENT `statuses` ahead of the first
    /// comparison, a session sitting in a steady, multi-tick `answerless` episode (the ladder's
    /// own comment documents these running 24 minutes to 3 hours) would trip that first
    /// comparison on `answerless` alone, publish `false`, and then have the second comparison
    /// immediately republish `true` — every tick, for the life of the episode. That is exactly
    /// the cost the comment beside this code already names as unacceptable ("re-assigning an
    /// equal value at 2 Hz would invalidate the whole sidebar twice a second"), just not
    /// guarded for this field until the seed was added.
    ///
    /// A tick that changes nothing else at all — same activity, same `waitingFor`, same
    /// `subagentCount`, same episode already past its debounce — must publish `statuses`
    /// zero times, not once and not twice: `@Published` sends nothing when the assigned value
    /// equals the current one, and with the seed in place, both of `commitStatuses`'s
    /// assignments see `next == statuses` on a tick like this.
    func testAnUnchangedTickForAnAnswerlessSessionPublishesStatusesNoMoreThanOnce() {
        let (store, id) = makeStore(probe: { _ in .failure("prompt_changed") })
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        advance(5)
        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])
        XCTAssertTrue(store.status(for: id)?.answerless ?? false, "the debounce must have fired")

        var publishCount = 0
        // `dropFirst()`: `@Published`'s projected publisher replays the current value to a new
        // subscriber immediately, which is not a tick this test is about — only changes from
        // here on count.
        let subscription = store.$statuses.dropFirst().sink { _ in publishCount += 1 }
        defer { subscription.cancel() }

        store.applyRegistryForTesting([id: SessionStatus(activity: .waiting)])

        XCTAssertLessThanOrEqual(
            publishCount, 1,
            "the pre-fix double assignment published this tick's unchanged status twice"
        )
        XCTAssertEqual(
            publishCount, 0,
            "nothing changed this tick, so `statuses` must not publish at all"
        )
    }
}
