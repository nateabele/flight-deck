import XCTest
import IntakeKit
@testable import FlightDeck

/// The contract's value types carry the few rules every branch must agree on: what counts as
/// an account's worst window, which models a catalog admits, and that each fake really stands
/// in for its protocol. Each later branch tests against these fakes, so a fake that silently
/// ignored its script would make four branches' tests lie at once.
final class ContractValuesTests: XCTestCase {
    func testWorstWindowIsHighestUtilization() {
        let r = UsageReading(account: AccountRef(harness: "claude", id: UUID(), label: "Work"),
                             windows: [UsageWindow(name: "five_hour", utilization: 0.4, resetsAt: nil),
                                       UsageWindow(name: "seven_day", utilization: 0.91, resetsAt: nil)],
                             readAt: Date(), source: "test", hardRejection: false)
        XCTAssertEqual(r.worstWindow?.name, "seven_day")
        XCTAssertNil(UsageReading(account: r.account, windows: [], readAt: Date(), source: "t", hardRejection: false).worstWindow)
    }

    func testCatalogsAdmitOnlyKnownModelsAndKnobs() {
        let cats = AdapterCatalogs([AdapterCatalog(harness: "codex",
            models: [ModelEntry(id: "gpt-6-sol", displayName: "GPT-6 Sol", knobs: ["effort"])],
            knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "gpt-6-sol", enabled: true)])
        XCTAssertTrue(cats.contains(ModelRef(harness: "codex", model: "gpt-6-sol")))
        XCTAssertFalse(cats.contains(ModelRef(harness: "codex", model: "nope")))
        XCTAssertFalse(cats.contains(ModelRef(harness: "claude", model: "opus")))
        XCTAssertTrue(cats.knobsValid(ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"])))
        XCTAssertFalse(cats.knobsValid(ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "max"])))
        XCTAssertFalse(cats.knobsValid(ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["agent": "x"])))
        XCTAssertEqual(cats.enabledModels, [ModelRef(harness: "codex", model: "gpt-6-sol")])
    }

    func testDisabledCatalogContributesNoModels() {
        let cats = AdapterCatalogs([AdapterCatalog(harness: "opencode", models: [ModelEntry(id: "ollama/q", displayName: "q", knobs: [])],
                                                   knobSchema: [:], defaultModel: nil, enabled: false)])
        XCTAssertEqual(cats.enabledModels, [])
    }

    func testFakesFollowTheirScripts() {
        let alloc = FakePoolAllocator()
        let lease = AccountLease(id: UUID(), pool: "p", account: AccountRef(harness: "codex", id: UUID(), label: "A"))
        alloc.leases["p"] = [lease]
        XCTAssertEqual(alloc.lease(pool: "p"), lease)
        XCTAssertNil(alloc.lease(pool: "p"), "a scripted lease is handed out once")
        alloc.release(lease)
        XCTAssertEqual(alloc.released, [lease])

        let reader = FakeCapacityReader()
        reader.byPool["p"] = [AccountHeadroom(account: lease.account, worstUtilization: 0.9, state: .overSoft, resetsAt: nil)]
        XCTAssertEqual(reader.headroom(pool: "p").first?.state, .overSoft)
        XCTAssertEqual(reader.headroom(pool: "other"), [])
    }

    func testFakeUsageMeterSourceStreamsWhatItIsFed() async {
        let src = FakeUsageMeterSource()
        let reading = UsageReading(account: AccountRef(harness: "claude", id: nil, label: "x"), windows: [],
                                   readAt: Date(timeIntervalSince1970: 1), source: "fake", hardRejection: true)
        src.send(reading); src.finish()
        var got: [UsageReading] = []
        for await r in src.readings { got.append(r) }
        XCTAssertEqual(got, [reading])
    }
}
