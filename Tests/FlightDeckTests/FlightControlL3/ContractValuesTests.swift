import XCTest
import IntakeKit
@testable import FlightDeck

/// The contract's value types carry the few rules every branch must agree on: what counts as
/// an account's worst window, which models a catalog admits, and that each fake really stands
/// in for its protocol. Each later branch tests against these fakes, so a fake that silently
/// ignored its script would make four branches' tests lie at once.
final class ContractValuesTests: XCTestCase {
    func testWorstWindowIsHighestUtilization() {
        let r = UsageReading(account: AccountRef(agent: .claude, id: UUID(), label: "Work"),
                             windows: [UsageWindow(name: "five_hour", utilization: 0.4, resetsAt: nil),
                                       UsageWindow(name: "seven_day", utilization: 0.91, resetsAt: nil)],
                             readAt: Date(), source: "test", hardRejection: false)
        XCTAssertEqual(r.worstWindow?.name, "seven_day")
        XCTAssertNil(UsageReading(account: r.account, windows: [], readAt: Date(), source: "t", hardRejection: false).worstWindow)
    }

    func testCatalogsAdmitOnlyKnownModelsAndKnobs() {
        let cats = AdapterCatalogs([AdapterCatalog(agent: .codex,
            models: [ModelEntry(id: "gpt-6-sol", displayName: "GPT-6 Sol", knobs: ["effort"])],
            knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "gpt-6-sol", enabled: true)])
        XCTAssertTrue(cats.contains(ModelRef(agent: .codex, model: "gpt-6-sol")))
        XCTAssertFalse(cats.contains(ModelRef(agent: .codex, model: "nope")))
        XCTAssertFalse(cats.contains(ModelRef(agent: .claude, model: "opus")))
        XCTAssertTrue(cats.knobsValid(ModelRef(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "high"])))
        XCTAssertFalse(cats.knobsValid(ModelRef(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "max"])))
        XCTAssertFalse(cats.knobsValid(ModelRef(agent: .codex, model: "gpt-6-sol", knobs: ["agent": "x"])))
        XCTAssertEqual(cats.enabledModels, [ModelRef(agent: .codex, model: "gpt-6-sol")])
    }

    func testDisabledCatalogContributesNoModels() {
        let cats = AdapterCatalogs([AdapterCatalog(agent: .gemini, models: [ModelEntry(id: "ollama/q", displayName: "q", knobs: [])],
                                                   knobSchema: [:], defaultModel: nil, enabled: false)])
        XCTAssertEqual(cats.enabledModels, [])
    }

    func testFakesFollowTheirScripts() {
        let alloc = FakePoolAllocator()
        let lease = AccountLease(id: UUID(), pool: "p", account: AccountRef(agent: .codex, id: UUID(), label: "A"))
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
        let reading = UsageReading(account: AccountRef(agent: .claude, id: nil, label: "x"), windows: [],
                                   readAt: Date(timeIntervalSince1970: 1), source: "fake", hardRejection: true)
        src.send(reading); src.finish()
        var got: [UsageReading] = []
        for await r in src.readings { got.append(r) }
        XCTAssertEqual(got, [reading])
    }

    func testUnroutableAssignmentRoundTripsItsReason() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let a = Assignment.unroutable(kind: "docs", reason: "no enabled model", at: at)
        XCTAssertTrue(a.isUnroutable)
        XCTAssertEqual(a.unroutableReason, "no enabled model")
        XCTAssertEqual(a.block.source.reason, "unroutable: no enabled model")
        XCTAssertEqual(a.block.source.by, .default)
        XCTAssertFalse(a.block.pinned)
        XCTAssertEqual(a.block.kind, "docs")
    }

    func testRoutableAssignmentIsNotUnroutable() {
        let block = ExecutionBlock(kind: "k", agent: .codex, model: "m", pool: "p",
                                   source: AssignmentSource(by: .rule, reason: "unroutable: looks odd", at: Date()))
        let a = Assignment(block: block)
        XCTAssertFalse(a.isUnroutable)
        XCTAssertNil(a.unroutableReason)
    }

    func testAccountRefIdentityIgnoresLabelWhenIdPresent() {
        let id = UUID()
        let a = AccountRef(agent: .claude, id: id, label: "Work")
        let b = AccountRef(agent: .claude, id: id, label: "Work (renamed)")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertNotEqual(a, AccountRef(agent: .codex, id: id, label: "Work"))
    }

    func testAccountRefWithoutIdComparesByLabel() {
        let a = AccountRef(agent: .codex, id: nil, label: "slot 1")
        XCTAssertNotEqual(a, AccountRef(agent: .codex, id: nil, label: "slot 2"))
        XCTAssertEqual(a, AccountRef(agent: .codex, id: nil, label: "slot 1"))
        XCTAssertNotEqual(a, AccountRef(agent: .codex, id: UUID(), label: "slot 1"))
    }

    func testDuplicateHarnessCatalogIsListedOnce() {
        func cat(_ model: String) -> AdapterCatalog {
            AdapterCatalog(agent: .codex, models: [ModelEntry(id: model, displayName: model, knobs: [])],
                           knobSchema: [:], defaultModel: nil, enabled: true)
        }
        let cats = AdapterCatalogs([cat("first"), cat("second")])
        XCTAssertEqual(cats.order, [.codex])
        XCTAssertEqual(cats.enabledModels, [ModelRef(agent: .codex, model: "first")])
    }

    func testDefaultPoolDirectoryHasOnePoolPerHarness() {
        let dir = DefaultPoolDirectory(agents: [.claude, .codex])
        XCTAssertEqual(dir.pools().map(\.id), ["claude-default", "codex-default"])
        XCTAssertEqual(dir.pools().map(\.agent), [.claude, .codex])
        XCTAssertEqual(dir.defaultPool(for: .codex), "codex-default")
        XCTAssertNil(dir.defaultPool(for: .gemini))
    }

    func testFakePoolDirectoryFollowsItsScript() {
        let fake = FakePoolDirectory()
        XCTAssertEqual(fake.pools(), [])
        XCTAssertNil(fake.defaultPool(for: .codex))
        fake.summaries = [PoolSummary(id: "p", agent: .codex, label: "P")]
        fake.defaults = [.codex: "p"]
        XCTAssertEqual(fake.pools().first?.label, "P")
        XCTAssertEqual(fake.defaultPool(for: .codex), "p")
    }
}
