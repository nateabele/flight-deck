import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone's own log, read back through the same `OSLogStore` call the Mac's fetch reaches.
///
/// **A real store, not a stub, because the risky part is the store.** Everything else here is
/// arithmetic; what can silently return nothing is the predicate, the scope and the position —
/// a subsystem that quietly became the test host's, a category filter that matches no entry, or
/// a `.currentProcessIdentifier` read that finds `info`-level lines are not persisted. Every
/// one of those fails as "empty", which is exactly what a working quiet phone looks like, so
/// only an end-to-end read can tell them apart.
@MainActor
final class PhoneLogTests: XCTestCase {
    /// os_log's write is asynchronous — the line is handed to the logging daemon and becomes
    /// queryable a moment later — so a read taken immediately after a write legitimately misses
    /// it. Polling rather than sleeping a fixed interval keeps the fast case fast and the slow
    /// case passing.
    private func waitForEntry(
        containing needle: String, timeout: TimeInterval = 5
    ) async throws -> WirePhoneLogs {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch PhoneLog.entries(seconds: 60, limit: PhoneLogLimits.maxEntries) {
            case .failure(let refusal):
                throw XCTSkip("OSLogStore refused this simulator: \(refusal.code)")
            case .success(let logs):
                if logs.entries.contains(where: { $0.message.contains(needle) }) { return logs }
                guard Date() < deadline else {
                    XCTFail(
                        "\"\(needle)\" never became readable"
                            + " — \(logs.entries.count) entries seen"
                    )
                    return logs
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func testALineTheAppLoggedComesBackThroughTheStore() async throws {
        let marker = "phone-log-test-\(UUID().uuidString)"
        PhoneLog.prompt.notice("\(marker, privacy: .public)")

        let logs = try await waitForEntry(containing: marker)
        let entry = try XCTUnwrap(logs.entries.last { $0.message.contains(marker) })
        // The category is what a reader scans the fetched file by, and it must be the
        // logger's, not the subsystem's or a default.
        XCTAssertEqual(entry.category, "prompt")
        // `notice`, not `info`: os_log keeps `info` in a memory ring and does not persist it,
        // so a line written at that level is unreadable minutes later — which is the only time
        // anyone asks this log a question. See `PhoneLog.entries`.
        XCTAssertEqual(entry.level, "notice")
        XCTAssertFalse(entry.at.isEmpty)
    }

    /// Oldest first, so the file the Mac appends to reads in the order things happened.
    func testEntriesComeBackInTheOrderTheyWereLogged() async throws {
        let run = UUID().uuidString
        PhoneLog.connection.notice("\("order-first-\(run)", privacy: .public)")
        PhoneLog.connection.notice("\("order-second-\(run)", privacy: .public)")

        let logs = try await waitForEntry(containing: "order-second-\(run)")
        let first = try XCTUnwrap(logs.entries.firstIndex { $0.message.contains("order-first-\(run)") })
        let second = try XCTUnwrap(logs.entries.firstIndex { $0.message.contains("order-second-\(run)") })
        XCTAssertLessThan(first, second)
    }

    /// The cap keeps the **newest** entries and says it bit. A truncated answer that dropped
    /// the end of the story would throw away the part a failure is in, and one that did not
    /// report `truncated` would be indistinguishable from a quiet phone.
    func testTheCapKeepsTheNewestEntriesAndReportsThatItBit() async throws {
        let run = UUID().uuidString
        for index in 0..<4 {
            PhoneLog.connection.notice("\("cap-\(index)-\(run)", privacy: .public)")
        }
        _ = try await waitForEntry(containing: "cap-3-\(run)")

        guard case .success(let capped) = PhoneLog.entries(seconds: 60, limit: 2) else {
            return XCTFail("OSLogStore refused a capped read")
        }
        XCTAssertEqual(capped.entries.count, 2)
        XCTAssertTrue(capped.truncated)
        // Whatever else this test bundle logged, the two kept entries are the last two written
        // to this store — and `cap-0` is not among them.
        XCTAssertFalse(capped.entries.contains { $0.message.contains("cap-0-\(run)") })
    }

    /// Both bounds are clamped on this side rather than trusted from the Mac, the same
    /// contract the Mac's own `.search` handler keeps against a phone: a peer-side bug asking
    /// for a week of entries must not cost this phone an unbounded read.
    func testAnOversizedRequestIsClampedRatherThanHonoured() async throws {
        let marker = "clamp-\(UUID().uuidString)"
        PhoneLog.answer.notice("\(marker, privacy: .public)")
        _ = try await waitForEntry(containing: marker)

        guard case .success(let logs) = PhoneLog.entries(
            seconds: PhoneLogLimits.maxSeconds * 10, limit: PhoneLogLimits.maxEntries * 10
        ) else {
            return XCTFail("OSLogStore refused an oversized read")
        }
        XCTAssertLessThanOrEqual(logs.entries.count, PhoneLogLimits.maxEntries)
    }

    /// **One line per change, and never one per render.**
    ///
    /// `SessionTimelineModel.blocked(agent:activity:call:)` is read from a view body, so it
    /// runs on every re-evaluation — a `notice` on the call itself would put hundreds of
    /// identical lines into the window a fetch has to carry and drown the transition that
    /// matters. Driven here through the real model, over a real store, because the property
    /// under test is exactly "the second identical call writes nothing".
    func testAnUnchangedPromptIsLoggedOnceHoweverOftenTheScreenAsks() async throws {
        let session = UUID()
        let model = SessionTimelineModel(sessionID: session, fleet: StubFleetForLogging())
        // Nothing derived and nothing claimed by the Mac — the state a session screen is in
        // most of the time, and the one a per-call log would flood from.
        for _ in 0..<5 {
            _ = model.blocked(agent: "claude", activity: "waiting", call: .noPrompt)
        }
        // A different `call` is a real change and must produce its own line.
        _ = model.blocked(agent: "claude", activity: "waiting", call: .call("toolu_TWO"))

        let logs = try await waitForEntry(containing: "toolu_TWO")
        let mine = logs.entries.filter { $0.message.contains(session.uuidString) }
        XCTAssertEqual(
            mine.count, 2,
            "five identical derivations and one change must be two lines, not six: \(mine)"
        )
        XCTAssertTrue(mine[0].message.hasSuffix("derived=none mac=none shown=none"))
        XCTAssertTrue(mine[1].message.hasSuffix("derived=none mac=toolu_TWO shown=none"))
    }

    /// Only the categories this app owns cross the device boundary. Named rather than derived
    /// in `PhoneLog`, so a category added later for something noisy does not start shipping
    /// itself to a Mac by accident — this is that list, asserted.
    func testOnlyTheAppsOwnCategoriesAreReturned() async throws {
        let marker = "categories-\(UUID().uuidString)"
        PhoneLog.answer.notice("\(marker, privacy: .public)")

        let logs = try await waitForEntry(containing: marker)
        for entry in logs.entries {
            XCTAssertTrue(
                PhoneLog.categories.contains(entry.category),
                "\(entry.category) is not one of this app's diagnostic categories"
            )
        }
    }
}

/// The narrowest fleet a `SessionTimelineModel` will accept. Every verb is a no-op: the
/// property under test is what the model *logs* when it is asked what is blocked, and nothing
/// about that reaches a Mac.
@MainActor
private final class StubFleetForLogging: TimelinePaging, PromptSending, PromptAnswering,
                                         PresenceReporting {
    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {}
    func markRead(_ id: UUID) {}
    func viewing(_ session: UUID?) {}
    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {}
    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {}
}
